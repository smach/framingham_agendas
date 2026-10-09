# send_email.R
#
# Sends an email listing new hearing items in the districts you monitor.
#
# This script is sourced at the end of agendas_to_geocode.R, so it expects the
# data frame `hearings_with_districts` (this run's new hearings) to already
# exist. SMTP settings come from environment variables; see email_config.R.

source("email_config.R")

# Districts to watch. Edit this vector to change which districts trigger email.
districts_to_notify <- c("1", "2", "3", "4")

new_items_to_notify <- hearings_with_districts %>%
  filter(District %in% districts_to_notify)

if (nrow(new_items_to_notify) > 0) {
  # e.g. "District 4" or "Districts 3, 4"
  districts_with_items <- unique(new_items_to_notify$District)
  districts_label <- paste0(
    "District", if (length(districts_with_items) > 1) "s" else "", " ",
    paste(districts_with_items, collapse = ", ")
  )

  # Create email body: a header line, then one block per hearing item
  email_body <- paste0("New hearing items found in ", districts_label, ":\n\n")

  for (i in 1:nrow(new_items_to_notify)) {
    item <- new_items_to_notify[i, ]
    email_body <- paste0(
      email_body,
      "District: ", item$District, "\n",
      "Date: ", item$Date, "\n",
      "Board: ", item$Board, "\n",
      "Description: ", item$description, "\n",
      "Address: ", item$address, "\n",
      "URL: ", item$URL, "\n\n",
      "---\n\n"
    )
  }

  # Stop early with a clear message if a secret is missing or malformed.
  # (Any error here is caught and reported by agendas_to_geocode.R.)
  check_email_settings()

  # Create and send email
  email <- emayili::envelope(
    to = get_email_setting("EMAIL_TO"),
    from = get_email_setting("EMAIL_FROM"),
    subject = paste0(
      "New Framingham Hearings - ", nrow(new_items_to_notify), " items in ", districts_label
    ),
    text = email_body
  )

  # Sends via the SMTP settings in the environment, retrying up to 3 times
  # (see send_with_retries() in email_config.R)
  send_with_retries(email)
  message("Email sent: ", nrow(new_items_to_notify), " new hearing items in monitored districts")
} else {
  message("No new hearing items in monitored districts (",
          paste(districts_to_notify, collapse = ", "), ")")
}
