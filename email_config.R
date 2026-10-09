# email_config.R
#
# Shared email helpers used by send_email.R (the real notifications) and
# test_email.R (the on-demand test). Keeping the SMTP setup in one place means
# the test checks exactly the same configuration the real emails use.
#
# All settings come from environment variables, which GitHub Actions fills in
# from the repository secrets (see .github/workflows/process-agendas.yml).

library(emayili)

# The environment variables needed to send email
email_env_vars <- c(
  "SMTP_HOST", "SMTP_PORT", "SMTP_USERNAME", "SMTP_PASSWORD",
  "EMAIL_TO", "EMAIL_FROM"
)

# Read one setting and strip leading/trailing whitespace. A secret pasted with
# a trailing space or newline is a common, invisible cause of login failures.
get_email_setting <- function(name) {
  trimws(Sys.getenv(name))
}

# Print a safe summary of the email settings and stop if any are unusable.
#
# This never prints the values themselves, only whether each one is set and
# whether it had extra whitespace around it, so it is safe in public logs.
check_email_settings <- function() {
  raw_values <- Sys.getenv(email_env_vars)

  message("Email settings check:")
  for (name in email_env_vars) {
    value <- raw_values[[name]]
    status <- if (trimws(value) == "") "MISSING" else "set"
    if (value != trimws(value) && trimws(value) != "") {
      status <- paste(status, "(had extra spaces/newlines; they will be ignored)")
    }
    message("  ", name, ": ", status)
  }

  missing <- email_env_vars[trimws(raw_values) == ""]
  if (length(missing) > 0) {
    stop("Missing email settings: ", paste(missing, collapse = ", "),
         ". Add them under Settings > Secrets and variables > Actions.")
  }

  # suppressWarnings() hides R's "NAs introduced by coercion" warning;
  # we check for NA ourselves and give a clearer message.
  port <- suppressWarnings(as.integer(get_email_setting("SMTP_PORT")))
  if (is.na(port)) {
    stop("SMTP_PORT must be a number such as 587 or 465.")
  }

  invisible(TRUE)
}

# Build the emayili SMTP "server" function from the environment variables.
#
# emayili picks the right encryption from the port: 465 uses SMTPS,
# 587 uses STARTTLS.
#
# max_times = 1 turns off emayili's own retries. Its retry wrapper (from purrr)
# throws away the real error and only reports "Request failed after 5
# attempts.", which is exactly the unhelpful message in the old logs.
# send_with_retries() below retries instead and keeps the real error.
make_smtp_server <- function() {
  emayili::server(
    host = get_email_setting("SMTP_HOST"),
    port = as.integer(get_email_setting("SMTP_PORT")),
    username = get_email_setting("SMTP_USERNAME"),
    password = get_email_setting("SMTP_PASSWORD"),
    max_times = 1
  )
}

# Send an emayili envelope, retrying a few times for brief network hiccups.
#
# Each failed attempt's real reason (e.g. "Login denied") is printed, and if
# every attempt fails, the last real error is raised for the caller to report.
#
# Keep verbose = FALSE: verbose output includes the SMTP login exchange,
# which can expose an encoded copy of the password in public Actions logs.
send_with_retries <- function(email, tries = 3, wait_seconds = 5) {
  smtp <- make_smtp_server()

  for (attempt in seq_len(tries)) {
    # tryCatch() returns NULL on success or the error object on failure
    error <- tryCatch(
      {
        smtp(email, verbose = FALSE)
        NULL
      },
      error = function(e) e
    )

    if (is.null(error)) {
      return(invisible(TRUE))
    }

    message("Send attempt ", attempt, " of ", tries, " failed: ", conditionMessage(error))
    if (attempt < tries) Sys.sleep(wait_seconds)
  }

  stop(error)
}

# Turn an R error into a readable one-line description, so it fits on one
# line in the GitHub annotation (curl errors sometimes contain newlines).
describe_email_error <- function(e) {
  gsub("\\s*\n\\s*", " ", trimws(conditionMessage(e)))
}

# Record an email failure so it can't go unnoticed.
#
# 1. Prints the error in the log.
# 2. When running in GitHub Actions, prints a special "::error::" line, which
#    GitHub shows as a red annotation on the run's summary page.
# 3. Writes email_error.txt. A later workflow step checks for this file and
#    marks the run as failed after the data has been committed, so GitHub
#    sends you its usual "workflow failed" notification.
report_email_failure <- function(error_text) {
  message("Email sending failed: ", error_text)

  if (identical(Sys.getenv("GITHUB_ACTIONS"), "true")) {
    cat("::error title=Email notification failed::", error_text, "\n", sep = "")
  }

  writeLines(error_text, "email_error.txt")
  invisible(NULL)
}
