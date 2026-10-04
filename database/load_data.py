"""Load the cleaned project CSVs into the local PostgreSQL database."""

# Allows the use of modern Python type-hint syntax
# without worrying about Python version evaluation.
from __future__ import annotations

# csv → Used to read and validate CSV files
import csv

# getpass → Used to get the current OS username
import getpass

# os → Used to read environment variables
import os

# shutil → Used to find the psql executable
import shutil

# subprocess → Used to execute PostgreSQL commands from Python
import subprocess

# Path → Modern way of working with file/folder paths
from pathlib import Path


# ---------------------------------------------------------
# 1. DATABASE CONFIGURATION
# ---------------------------------------------------------

# Read database name from PGDATABASE environment variable.
# If it is not set, use the default database name.
DATABASE = os.environ.get(
    "PGDATABASE",
    "netflix_customer_intelligence"
)


# PROJECT_ROOT = root folder of the project.
#
# __file__ → current Python script
# resolve() → converts it to an absolute path
# parents[1] → moves two levels upward
PROJECT_ROOT = Path(__file__).resolve().parents[1]


# Location of cleaned CSV files.
#
# If CLEAN_DATA_DIR environment variable exists,
# use that path.
#
# Otherwise use:
# project_root/data/processed
DATA_DIR = Path(
    os.environ.get(
        "CLEAN_DATA_DIR",
        PROJECT_ROOT / "data" / "processed"
    )
)


# ---------------------------------------------------------
# 2. DEFINE TABLE LOADING ORDER AND CSV COLUMNS
# ---------------------------------------------------------

# We explicitly define:
#
# table name
# +
# expected CSV column order
#
# This is important because CSV column order may not
# exactly match PostgreSQL table column order.
LOAD_ORDER = (

    # customers table
    (
        "customers",
        (
            "customer_id",
            "first_name",
            "last_name",
            "age",
            "gender",
            "country",
            "city",
            "registration_date",
            "acquisition_channel",
            "customer_segment",
            "preferred_language",
        ),
    ),

    # subscription_plans table
    (
        "subscription_plans",
        (
            "plan_id",
            "plan_name",
            "monthly_price",
            "video_quality",
            "max_devices",
            "advertisements",
        ),
    ),

    # content table
    (
        "content",
        (
            "content_id",
            "title",
            "content_type",
            "genre",
            "release_year",
            "duration_minutes",
            "content_language",
            "production_country",
            "maturity_rating",
        ),
    ),

    # subscriptions table
    (
        "subscriptions",
        (
            "subscription_id",
            "customer_id",
            "plan_id",
            "subscription_start_date",
            "subscription_end_date",
            "subscription_status",
            "auto_renew",
            "cancellation_date",
            "cancellation_reason",
            "monthly_price",
        ),
    ),

    # viewing_activity table
    (
        "viewing_activity",
        (
            "viewing_id",
            "customer_id",
            "content_id",
            "viewing_date",
            "watch_duration_minutes",
            "completion_percentage",
            "device_type",
            "login_location",
            "session_duration_minutes",
        ),
    ),

    # payments table
    (
        "payments",
        (
            "payment_id",
            "customer_id",
            "payment_date",
            "amount",
            "payment_method",
            "payment_status",
            "failed_payment_reasons",
            "subscription_id",
        ),
    ),

    # support_tickets table
    (
        "support_tickets",
        (
            "ticket_id",
            "customer_id",
            "ticket_date",
            "issue_category",
            "issue_subcategory",
            "priority",
            "ticket_status",
            "resolution_time_hours",
            "customer_satisfaction_score",
            "ticket_description",
            "support_agent_id",
        ),
    ),

    # customer_feedback table
    (
        "customer_feedback",
        (
            "feedback_id",
            "customer_id",
            "feedback_date",
            "rating",
            "feedback_text",
            "sentiment_label",
        ),
    ),

    # churn_labels table
    (
        "churn_labels",
        (
            "customer_id",
            "churned",
            "churn_date",
            "churn_reason",
        ),
    ),
)


# ---------------------------------------------------------
# 3. FIND THE PSQL COMMAND
# ---------------------------------------------------------

def psql_command() -> list[str]:

    # First check whether the user explicitly configured
    # a PostgreSQL executable using the PSQL environment variable.
    configured_path = os.environ.get("PSQL")

    # If PSQL is not configured, search for psql
    # in the system PATH.
    binary = configured_path or shutil.which("psql")

    # If psql is still not found,
    # check the default Postgres.app location on macOS.
    if binary is None:

        app_binary = Path(
            "/Applications/Postgres.app/Contents/Versions/latest/bin/psql"
        )

        # Check whether the file actually exists.
        if app_binary.is_file():
            binary = str(app_binary)

    # If psql cannot be found anywhere,
    # stop the program with an error.
    if binary is None:
        raise SystemExit(
            "psql was not found; install PostgreSQL or set PSQL."
        )

    # Basic psql command.
    #
    # --no-psqlrc
    # prevents user's custom psql configuration
    # from affecting this script.
    #
    # ON_ERROR_STOP=1
    # tells PostgreSQL to stop immediately if an error occurs.
    command = [
        binary,
        "--no-psqlrc",
        "--set",
        "ON_ERROR_STOP=1",
    ]

    # PostgreSQL host.
    # Default is /tmp, which is commonly used by
    # local PostgreSQL installations on macOS.
    host = os.environ.get("PGHOST", "/tmp")

    # PostgreSQL username.
    # If PGUSER is not defined,
    # use the current operating-system username.
    user = os.environ.get(
        "PGUSER",
        getpass.getuser()
    )

    # Add connection information.
    command.extend(
        (
            "--host",
            host,
            "--username",
            user,
            "--dbname",
            DATABASE,
        )
    )

    # If PGPORT exists, add it.
    if port := os.environ.get("PGPORT"):
        command.extend(
            (
                "--port",
                port,
            )
        )

    # Return the complete psql command.
    return command


# ---------------------------------------------------------
# 4. RUN SQL FROM PYTHON
# ---------------------------------------------------------

def run_psql(sql: str) -> str:

    # Execute SQL using PostgreSQL's psql command-line tool.
    result = subprocess.run(

        # Combine the PostgreSQL command
        # with the SQL command.
        [
            *psql_command(),

            # Return only query results.
            "--tuples-only",

            # Remove alignment/formatting.
            "--no-align",

            # Execute the SQL command.
            "--command",
            sql,
        ],

        # Raise an exception if PostgreSQL returns an error.
        check=True,

        # Capture the command output.
        capture_output=True,

        # Treat output as text instead of bytes.
        text=True,
    )

    # Return the output after removing extra whitespace.
    return result.stdout.strip()


# ---------------------------------------------------------
# 5. VALIDATE CSV FILE AND COUNT ROWS
# ---------------------------------------------------------

def csv_row_count(
    path: Path,
    expected_columns: tuple[str, ...]
) -> int:

    # Make sure the CSV file exists.
    if not path.is_file():
        raise SystemExit(
            f"Cleaned CSV not found: {path}"
        )

    # Open CSV using UTF-8.
    #
    # utf-8-sig also handles files containing a BOM.
    with path.open(
        "r",
        newline="",
        encoding="utf-8-sig"
    ) as csv_file:

        # Create CSV reader.
        reader = csv.reader(csv_file)

        # Read the first row = header.
        header = next(reader, None)

        # Compare actual CSV columns with expected columns.
        if header != list(expected_columns):

            # Stop if the structure is incorrect.
            raise SystemExit(
                f"Unexpected header in {path.name}: "
                f"{header!r}; "
                f"expected {list(expected_columns)!r}"
            )

        # Count remaining rows.
        return sum(
            1
            for _ in reader
        )


# ---------------------------------------------------------
# 6. MAIN DATA LOADING PROCESS
# ---------------------------------------------------------

def main() -> None:

    # Validate every CSV and store its expected row count.
    #
    # Example:
    #
    # {
    #     "customers": 10000,
    #     "payments": 25000,
    #     ...
    # }
    expected_counts = {
        table: csv_row_count(
            DATA_DIR / f"{table}.csv",
            columns
        )
        for table, columns in LOAD_ORDER
    }


    # -----------------------------------------------------
    # Check whether database tables already contain data
    # -----------------------------------------------------

    existing_counts = run_psql(

        # Check row counts in all 9 tables.
        #
        # If at least one table contains rows,
        # bool_or(n <> 0) becomes TRUE.
        "SELECT COALESCE(bool_or(n <> 0), false)::text "

        "FROM ("

        "SELECT count(*) AS n FROM customers "
        "UNION ALL "

        "SELECT count(*) FROM subscription_plans "
        "UNION ALL "

        "SELECT count(*) FROM content "
        "UNION ALL "

        "SELECT count(*) FROM subscriptions "
        "UNION ALL "

        "SELECT count(*) FROM viewing_activity "
        "UNION ALL "

        "SELECT count(*) FROM payments "
        "UNION ALL "

        "SELECT count(*) FROM support_tickets "
        "UNION ALL "

        "SELECT count(*) FROM customer_feedback "
        "UNION ALL "

        "SELECT count(*) FROM churn_labels"

        ") AS counts"
    )


    # If any table already has records,
    # stop instead of accidentally appending duplicates.
    if existing_counts != "false":

        raise SystemExit(
            "At least one target table already contains rows; "
            "refusing to append. "
            "Use an empty database or clear it deliberately "
            "before loading."
        )


    # -----------------------------------------------------
    # 7. BUILD POSTGRES COPY COMMANDS
    # -----------------------------------------------------

    # Start a database transaction.
    #
    # Either all data gets loaded successfully,
    # or the transaction can be rolled back on failure.
    copy_commands = ["BEGIN;"]


    # Process every table.
    for table, columns in LOAD_ORDER:

        # Build absolute path to the CSV file.
        csv_path = (
            DATA_DIR / f"{table}.csv"
        ).resolve()


        # Escape single quotes in the path.
        #
        # This allows paths containing spaces or quotes
        # to be handled safely by psql.
        quoted_path = (
            "'"
            + str(csv_path).replace("'", "''")
            + "'"
        )


        # Convert tuple of column names into:
        #
        # column1, column2, column3
        column_list = ", ".join(columns)


        # Build PostgreSQL \copy command.
        #
        # \copy reads the CSV from the local machine.
        copy_commands.append(

            f"\\copy {table} ({column_list}) "
            f"FROM {quoted_path} "
            "WITH (FORMAT csv, HEADER true)"
        )


    # Finish the transaction.
    copy_commands.append("COMMIT;")


    # -----------------------------------------------------
    # 8. EXECUTE ALL COPY COMMANDS
    # -----------------------------------------------------

    subprocess.run(

        # PostgreSQL connection command
        psql_command(),

        # Send all COPY commands to psql.
        input="\n".join(copy_commands) + "\n",

        # Raise error if loading fails.
        check=True,

        # Treat input as text.
        text=True,
    )


    # -----------------------------------------------------
    # 9. VERIFY ROW COUNTS AFTER LOADING
    # -----------------------------------------------------

    # Query PostgreSQL and get actual row count
    # for every table.
    actual_counts = {

        table: int(
            run_psql(
                f"SELECT count(*) FROM {table}"
            )
        )

        for table, _ in LOAD_ORDER
    }


    # Compare:
    #
    # CSV row count
    #       VS
    # PostgreSQL row count
    #
    # If they don't match, something went wrong.
    failures = {

        table: (
            expected_counts[table],
            actual_counts[table]
        )

        for table in expected_counts

        if expected_counts[table]
        != actual_counts[table]
    }


    # Stop if any table has a row-count mismatch.
    if failures:

        raise SystemExit(
            f"Imported row counts do not match CSVs: "
            f"{failures}"
        )


    # -----------------------------------------------------
    # 10. CHECK PAYMENT → SUBSCRIPTION RELATIONSHIP
    # -----------------------------------------------------

    # Find payments whose subscription_id
    # does not exist in subscriptions.
    payment_subscription_orphans = int(

        run_psql(

            "SELECT count(*) "
            "FROM payments p "

            "LEFT JOIN subscriptions s "
            "USING (subscription_id) "

            "WHERE s.subscription_id IS NULL"
        )
    )


    # -----------------------------------------------------
    # 11. CHECK CUSTOMER REFERENCES
    # -----------------------------------------------------

    # Collect customer IDs used by child tables.
    #
    # Then check whether every customer exists
    # in the customers table.
    customer_orphans = int(

        run_psql(

            "SELECT count(*) "

            "FROM ("

            "SELECT customer_id FROM subscriptions "

            "UNION ALL "

            "SELECT customer_id FROM viewing_activity "

            "UNION ALL "

            "SELECT customer_id FROM payments "

            "UNION ALL "

            "SELECT customer_id FROM support_tickets "

            "UNION ALL "

            "SELECT customer_id FROM customer_feedback "

            "UNION ALL "

            "SELECT customer_id FROM churn_labels"

            ") related "

            "LEFT JOIN customers c "
            "USING (customer_id) "

            "WHERE c.customer_id IS NULL"
        )
    )


    # -----------------------------------------------------
    # 12. CHECK VIEWING → CONTENT RELATIONSHIP
    # -----------------------------------------------------

    # Find viewing records where content_id
    # doesn't exist in the content table.
    content_orphans = int(

        run_psql(

            "SELECT count(*) "
            "FROM viewing_activity v "

            "LEFT JOIN content c "
            "USING (content_id) "

            "WHERE c.content_id IS NULL"
        )
    )


    # -----------------------------------------------------
    # 13. CHECK SUBSCRIPTION → PLAN RELATIONSHIP
    # -----------------------------------------------------

    # Find subscriptions where plan_id
    # doesn't exist in subscription_plans.
    plan_orphans = int(

        run_psql(

            "SELECT count(*) "
            "FROM subscriptions s "

            "LEFT JOIN subscription_plans p "
            "USING (plan_id) "

            "WHERE p.plan_id IS NULL"
        )
    )


    # -----------------------------------------------------
    # 14. STORE RELATIONSHIP VALIDATION RESULTS
    # -----------------------------------------------------

    relationship_counts = {

        "payment subscription IDs":
            payment_subscription_orphans,

        "customer references":
            customer_orphans,

        "viewing content references":
            content_orphans,

        "subscription plan references":
            plan_orphans,
    }


    # -----------------------------------------------------
    # 15. PRINT IMPORT RESULTS
    # -----------------------------------------------------

    print("Imported rows:")

    # Print number of records imported into each table.
    for table, count in actual_counts.items():

        print(
            f"  {table}: {count:,}"
        )


    # Print relationship validation results.
    print("Orphaned foreign-key references:")

    for relationship, count in relationship_counts.items():

        print(
            f"  {relationship}: {count}"
        )


    # -----------------------------------------------------
    # 16. FINAL VALIDATION
    # -----------------------------------------------------

    # If any orphaned relationship exists,
    # fail the process.
    if any(relationship_counts.values()):

        raise SystemExit(
            "Foreign-key relationship verification failed."
        )


# ---------------------------------------------------------
# 17. PYTHON ENTRY POINT
# ---------------------------------------------------------

# This ensures main() runs only when this file
# is executed directly.
#
# It will NOT run automatically if the file is imported
# into another Python script.
if __name__ == "__main__":
    main()