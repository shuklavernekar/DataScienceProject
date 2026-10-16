# Code flow:

# Load the cleaned customer and churn-label data.
# Set the feature cutoff to 2025-10-02 and exclude customers who registered after it.
# Build customer-level features from pre-cutoff viewing, subscription, payment, support-ticket, and feedback history. Churn labels and post-cutoff information are not used as predictors.
# Separate predictors (X) from the churn target (y).
# Make a stratified 80/20 train/test split.
# Impute missing values, scale numeric features, and one-hot encode categories within each model pipeline.
# Compare Logistic Regression, Random Forest, Gradient Boosting, and XGBoost when its dependencies are available. Use balanced sample weights and stratified 5-fold cross-validation.
# Select the model using cross-validated average precision, with ROC-AUC as a tie-breaker.
# Choose an F1-maximizing threshold from out-of-fold training predictions, then evaluate the selected model on the held-out test set.
# Print the requested metrics, confusion matrix, and retention-offer precision/recall discussion.

"""Train and evaluate a leakage-aware customer churn classifier.

Workflow: build features using only pre-cutoff history, split customers into
training and test sets, compare candidate classifiers with cross-validation,
choose a training-only decision threshold, then report one final test result.
"""

from ctypes.util import find_library
from importlib.util import find_spec
from pathlib import Path
import sys

import numpy as np
import pandas as pd
from sklearn.base import BaseEstimator, ClassifierMixin, clone
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import (
    GradientBoostingClassifier,
    RandomForestClassifier,
)
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (
    accuracy_score,
    average_precision_score,
    confusion_matrix,
    f1_score,
    precision_recall_curve,
    precision_score,
    recall_score,
    roc_auc_score,
)
from sklearn.model_selection import (
    StratifiedKFold,
    cross_val_predict,
    cross_validate,
    train_test_split,
)
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler
from sklearn.utils.class_weight import compute_sample_weight


RANDOM_STATE = 42
# Freeze feature history before the first observed churn date to avoid leakage.
FEATURE_CUTOFF = pd.Timestamp("2025-10-02")
DATA_DIR = Path(__file__).resolve().parents[1] / "data" / "processed"

# XGBoost needs both its Python package and, on macOS, the system OpenMP runtime.
# If either is unavailable, keep the other supported candidates runnable.
XGBClassifier = None
if find_spec("xgboost") is None:
    print("XGBoost candidate skipped: install the xgboost package to enable it.")
elif sys.platform == "darwin" and find_library("omp") is None:
    print(
        "XGBoost candidate skipped: the macOS OpenMP runtime (libomp) is "
        "missing. Install it with `brew install libomp`, then rerun."
    )
else:
    from xgboost import XGBClassifier


class BalancedClassifier(ClassifierMixin, BaseEstimator):
    """Apply balanced class weights inside every model fit, including CV folds."""

    def __init__(self, estimator):
        self.estimator = estimator

    def fit(self, X, y):
        # Recreate the wrapped estimator so each fold gets a fresh, unfitted model.
        self.estimator_ = clone(self.estimator)
        # Upweight churn examples to reduce bias toward the majority retained class.
        weights = compute_sample_weight(class_weight="balanced", y=y)
        self.estimator_.fit(X, y, sample_weight=weights)
        self.classes_ = self.estimator_.classes_
        return self

    def predict(self, X):
        return self.estimator_.predict(X)

    def predict_proba(self, X):
        return self.estimator_.predict_proba(X)


def most_common(series):
    """Return the most frequent non-null category for customer-level features."""
    modes = series.dropna().mode()
    return modes.iloc[0] if not modes.empty else np.nan


def load_model_data():
    """Build one customer-level row of features using only pre-cutoff events."""
    # Load target labels separately; dates and churn reasons are never predictors.
    labels = pd.read_csv(DATA_DIR / "churn_labels.csv")
    labels["churned"] = labels["churned"].astype(int)
    customers = pd.read_csv(
        DATA_DIR / "customers.csv", parse_dates=["registration_date"]
    )

    # Keep customer attributes that are available before churn; names and IDs do
    # not provide useful prediction signals, so they are excluded from X later.
    customer_features = customers[
        [
            "customer_id",
            "age",
            "gender",
            "country",
            "registration_date",
            "acquisition_channel",
            "customer_segment",
            "preferred_language",
        ]
    ].copy()
    customer_features = customer_features.loc[
        customer_features["registration_date"].le(FEATURE_CUTOFF)
    ].copy()
    # Measure tenure at the same cutoff for every eligible customer.
    customer_features["tenure_days"] = (
        FEATURE_CUTOFF - customer_features["registration_date"]
    ).dt.days

    # Keep only customers with labels and enforce a single customer row per ID.
    model_data = customer_features.merge(
        labels[["customer_id", "churned"]],
        on="customer_id",
        how="inner",
        validate="one_to_one",
    )

    # Summarize viewing engagement from activity on or before the feature cutoff.
    viewing = pd.read_csv(
        DATA_DIR / "viewing_activity.csv", parse_dates=["viewing_date"]
    )
    viewing = viewing.loc[viewing["viewing_date"].le(FEATURE_CUTOFF)]
    viewing_features = viewing.groupby("customer_id").agg(
        viewing_sessions=("viewing_id", "nunique"),
        watch_minutes=("watch_duration_minutes", "sum"),
        mean_completion_percentage=("completion_percentage", "mean"),
        distinct_devices=("device_type", "nunique"),
    )

    # Keep subscription history that started before the cutoff; deliberately
    # avoid current status, end date, and cancellation fields because those can
    # reveal the target directly.
    subscriptions = pd.read_csv(
        DATA_DIR / "subscriptions.csv",
        parse_dates=["subscription_start_date"],
    )
    subscriptions = subscriptions.loc[
        subscriptions["subscription_start_date"].le(FEATURE_CUTOFF)
    ].sort_values(
        ["customer_id", "subscription_start_date", "subscription_id"]
    )
    subscription_features = subscriptions.groupby("customer_id").agg(
        subscription_count=("subscription_id", "nunique"),
        latest_plan_id=("plan_id", "last"),
        latest_monthly_price=("monthly_price", "last"),
    )

    # Turn payment records into customer-level billing and payment-risk features.
    payments = pd.read_csv(
        DATA_DIR / "payments.csv", parse_dates=["payment_date"]
    )
    payments = payments.loc[payments["payment_date"].le(FEATURE_CUTOFF)].copy()
    payments["failed_payment"] = (
        payments["payment_status"].str.casefold().eq("failed").astype(int)
    )
    payment_features = payments.groupby("customer_id").agg(
        payment_count=("payment_id", "nunique"),
        failed_payment_count=("failed_payment", "sum"),
        total_payment_amount=("amount", "sum"),
        mean_payment_amount=("amount", "mean"),
        common_payment_method=("payment_method", most_common),
    )
    payment_features["failed_payment_rate"] = (
        payment_features["failed_payment_count"]
        / payment_features["payment_count"].replace(0, np.nan)
    )
    payment_features["failed_payment_rate"] = (
        payment_features["failed_payment_rate"].fillna(0)
    )

    # Use ticket counts and issue category only; exclude resolution/status fields
    # that may occur after the feature cutoff or reflect a churn outcome.
    tickets = pd.read_csv(
        DATA_DIR / "support_tickets.csv", parse_dates=["ticket_date"]
    )
    tickets = tickets.loc[tickets["ticket_date"].le(FEATURE_CUTOFF)]
    ticket_features = tickets.groupby("customer_id").agg(
        ticket_count=("ticket_id", "nunique"),
        common_ticket_category=("issue_category", most_common),
    )

    # Aggregate historical feedback ratings and positive sentiment proportions.
    feedback = pd.read_csv(
        DATA_DIR / "customer_feedback.csv", parse_dates=["feedback_date"]
    )
    feedback = feedback.loc[feedback["feedback_date"].le(FEATURE_CUTOFF)].copy()
    feedback["positive_feedback"] = (
        feedback["sentiment_label"].str.casefold().eq("positive").astype(int)
    )
    feedback_features = feedback.groupby("customer_id").agg(
        feedback_count=("feedback_id", "nunique"),
        mean_feedback_rating=("rating", "mean"),
        positive_feedback_share=("positive_feedback", "mean"),
    )

    # Join each history summary onto the eligible customer/label table.
    for features in (
        viewing_features,
        subscription_features,
        payment_features,
        ticket_features,
        feedback_features,
    ):
        model_data = model_data.merge(
            features, on="customer_id", how="left", validate="one_to_one"
        )

    # No matching event means zero events for count/sum/share features. Leave
    # averages missing so the fold-fitted imputer can handle them appropriately.
    zero_when_no_history = [
        "viewing_sessions",
        "watch_minutes",
        "distinct_devices",
        "subscription_count",
        "payment_count",
        "failed_payment_count",
        "total_payment_amount",
        "failed_payment_rate",
        "ticket_count",
        "feedback_count",
        "positive_feedback_share",
    ]
    model_data[zero_when_no_history] = model_data[
        zero_when_no_history
    ].fillna(0)

    # Separate predictors from identifiers, dates, and the target label.
    X = model_data.drop(
        columns=["customer_id", "churned", "registration_date"]
    )
    y = model_data["churned"]
    return X, y, model_data


def make_pipeline(preprocessor, estimator):
    """Keep feature transformation and classification together in CV folds."""
    return Pipeline(
        [
            ("preprocessor", preprocessor),
            ("classifier", BalancedClassifier(estimator)),
        ]
    )


def main():
    # Create features and print cohort information before model training.
    X, y, model_data = load_model_data()
    print(f"Feature cutoff: {FEATURE_CUTOFF.date()}")
    print(f"Eligible customers: {len(model_data):,}")
    print("Churn label counts (0 = retained, 1 = churned):")
    print(y.value_counts().sort_index().to_string())
    print(f"Churn rate: {y.mean():.1%}\n")

    # Hold out 20% for a final evaluation; stratification preserves churn rate.
    X_train, X_test, y_train, y_test = train_test_split(
        X,
        y,
        test_size=0.20,
        random_state=RANDOM_STATE,
        stratify=y,
    )

    # Identify column types from training data only. Imputation, scaling, and
    # one-hot categories are learned inside each pipeline fit to avoid leakage.
    numeric_features = X_train.select_dtypes(include="number").columns.tolist()
    categorical_features = X_train.select_dtypes(
        exclude="number"
    ).columns.tolist()
    preprocessor = ColumnTransformer(
        transformers=[
            (
                "numeric",
                Pipeline(
                    [
                        ("imputer", SimpleImputer(strategy="median")),
                        ("scaler", StandardScaler()),
                    ]
                ),
                numeric_features,
            ),
            (
                "categorical",
                Pipeline(
                    [
                        ("imputer", SimpleImputer(strategy="most_frequent")),
                        (
                            "onehot",
                            OneHotEncoder(
                                handle_unknown="ignore", sparse_output=False
                            ),
                        ),
                    ]
                ),
                categorical_features,
            ),
        ],
        remainder="drop",
    )

    # Compare a linear baseline with two tree ensembles and optional XGBoost.
    candidates = {
        "Logistic Regression": LogisticRegression(
            max_iter=2000, random_state=RANDOM_STATE
        ),
        "Random Forest": RandomForestClassifier(
            n_estimators=150,
            min_samples_leaf=3,
            random_state=RANDOM_STATE,
            n_jobs=1,
        ),
        "Gradient Boosting": GradientBoostingClassifier(
            n_estimators=100,
            learning_rate=0.05,
            max_depth=2,
            random_state=RANDOM_STATE,
        ),
    }
    if XGBClassifier is not None:
        candidates["XGBoost"] = XGBClassifier(
            n_estimators=300,
            max_depth=3,
            learning_rate=0.05,
            subsample=0.8,
            colsample_bytree=0.8,
            objective="binary:logistic",
            eval_metric="logloss",
            random_state=RANDOM_STATE,
            n_jobs=1,
            verbosity=0,
        )
    # Use identical stratified folds and metrics so candidate scores are
    # comparable. Average precision emphasizes ranking of the churn minority.
    cv = StratifiedKFold(
        n_splits=5, shuffle=True, random_state=RANDOM_STATE
    )
    scoring = {
        "average_precision": "average_precision",
        "roc_auc": "roc_auc",
        "precision": "precision",
        "recall": "recall",
        "f1": "f1",
        "accuracy": "accuracy",
    }

    # Cross-validate every candidate using training data only.
    cv_rows = []
    fitted_candidates = {}
    for name, estimator in candidates.items():
        print(f"Cross-validating {name}...", flush=True)
        pipeline = make_pipeline(preprocessor, estimator)
        scores = cross_validate(
            pipeline,
            X_train,
            y_train,
            cv=cv,
            scoring=scoring,
            n_jobs=1,
            error_score="raise",
        )
        fitted_candidates[name] = pipeline
        cv_rows.append(
            {
                "model": name,
                **{
                    metric: scores[f"test_{metric}"].mean()
                    for metric in scoring
                },
            }
        )

    # Select by PR-AUC, then ROC-AUC; the test set does not affect selection.
    cv_results = pd.DataFrame(cv_rows).sort_values(
        ["average_precision", "roc_auc"], ascending=False
    )
    print("5-fold cross-validation on training data:")
    print(cv_results.to_string(index=False, float_format=lambda value: f"{value:.3f}"))

    selected_name = cv_results.iloc[0]["model"]
    selected_pipeline = fitted_candidates[selected_name]
    print(f"\nSelected model by CV average precision: {selected_name}")

    # Generate out-of-fold training probabilities so threshold tuning does not
    # use predictions from a model trained on the same customer's label.
    out_of_fold_probabilities = cross_val_predict(
        selected_pipeline,
        X_train,
        y_train,
        cv=cv,
        method="predict_proba",
        n_jobs=1,
    )[:, 1]
    # Choose the threshold that maximizes training out-of-fold F1.
    precision_values, recall_values, thresholds = precision_recall_curve(
        y_train, out_of_fold_probabilities
    )
    f1_values = (
        2
        * precision_values[:-1]
        * recall_values[:-1]
        / (precision_values[:-1] + recall_values[:-1] + 1e-12)
    )
    best_threshold = float(thresholds[int(np.argmax(f1_values))])

    # Fit on all training rows and evaluate only once on the untouched test set.
    selected_pipeline.fit(X_train, y_train)
    test_probabilities = selected_pipeline.predict_proba(X_test)[:, 1]
    test_predictions = (test_probabilities >= best_threshold).astype(int)
    test_metrics = {
        "threshold": best_threshold,
        "accuracy": accuracy_score(y_test, test_predictions),
        "precision": precision_score(
            y_test, test_predictions, zero_division=0
        ),
        "recall": recall_score(y_test, test_predictions, zero_division=0),
        "f1": f1_score(y_test, test_predictions, zero_division=0),
        "roc_auc": roc_auc_score(y_test, test_probabilities),
        "average_precision": average_precision_score(
            y_test, test_probabilities
        ),
    }
    print("\nHeld-out test metrics at the training-only F1 threshold:")
    for metric, value in test_metrics.items():
        print(f"{metric:>18}: {value:.3f}")

    # Show the four outcome counts: true/false retained and true/false churn.
    matrix = confusion_matrix(y_test, test_predictions, labels=[0, 1])
    print("\nConfusion matrix (rows = actual [retained, churned], columns = predicted):")
    print(matrix)
    selected_cv = cv_results.iloc[0]
    print("\nModel-choice justification:")
    print(
        f"{selected_name} was selected because it achieved the strongest "
        f"5-fold average precision ({selected_cv['average_precision']:.3f}) "
        f"on the training data; cross-validated ROC-AUC was "
        f"{selected_cv['roc_auc']:.3f}. On the untouched test split, "
        f"precision was {test_metrics['precision']:.3f} and recall was "
        f"{test_metrics['recall']:.3f} at threshold "
        f"{best_threshold:.3f}. In a retention-offer setting, higher recall "
        "finds more customers who may churn but also sends more offers to "
        "customers who would have stayed; higher precision reduces wasted "
        "offers but misses more future churners. The F1-selected threshold "
        "balances those two rates for this baseline. Before deployment, "
        "adjust the threshold using offer cost, expected retained-customer "
        "value, campaign capacity, and a randomized holdout to measure "
        "incremental retention."
    )


if __name__ == "__main__":
    # Run the complete workflow when called as a script or from the notebook.
    main()
