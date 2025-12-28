
library(pdftools)
library(tidyRSS)
library(glue)
my_data_directory <- "data"

library(dplyr)
library(data.table)
library(tidyr)
library(stringr)
library(rio)
library(nanoparquet)

library(ellmer)
library(dplyr)
library(purrr)
library(tidygeocoder)
# library(emayili)

agenda_feed <- "https://framinghamma.granicus.com/ViewPublisherRSS.php?view_id=1&mode=agendas"

agenda_feed_results <- tidyRSS::tidyfeed(agenda_feed) |>
  mutate(
    Type = "Agenda"
  )




results <- agenda_feed_results |>
  mutate(
    Date = stringr::str_replace(item_title, ".*?\\s\\-\\s([A-Z][a-z][a-z]\\s\\d.*?$)", "\\1"),
    Date = lubridate::mdy(Date),
    Board = stringr::str_replace(item_title, "(^.*?)\\s\\-\\s([A-Z][a-z][a-z]\\s\\d.*?$)", "\\1"),
    ID = stringr::str_replace(item_link, ".*?event_id\\=(.*?$)", "\\1"),
    ID = stringr::str_replace(ID, ".*?clip_id\\=(.*?$)", "\\1"),
    ID = trimws(ID),
    ID = glue("{Type}_{ID}"),
    File = glue("{ID}.pdf"),
    URL = item_link
    # URL = glue("https://apps.machlis.com/shiny/framingham_meetings/{ID}.pdf")
  ) |>
  # dplyr::filter(as.Date(item_pub_date) >= as.Date("2023-05-01")) |>
  select(Date, ID, Meeting = item_title, Board, File, URL, Type, feed_title, item_pub_date, item_link) |>
  # Keep only most recent version for duplicate Date + Board combinations
  mutate(Board = str_squish(Board)) |>
  arrange(desc(item_pub_date)) |>
  distinct(Date, Board, .keep_all = TRUE)

existing_ids <- dir("data")
existing_ids <- gsub(".pdf", "", existing_ids, fixed = TRUE)
needed_files <- results |>
  filter(Board %in% c("Board of License Commissioners", "Planning Board", "Zoning Board of Appeals")) |>
  filter(!ID %in% existing_ids)

# Clean up PDFs older than 90 days
pdf_files <- list.files("data", pattern = "\\.pdf$", full.names = TRUE)
if (length(pdf_files) > 0) {
  file_info <- file.info(pdf_files)
  old_files <- pdf_files[difftime(Sys.time(), file_info$mtime, units = "days") > 90]
  if (length(old_files) > 0) {
    message("Deleting ", length(old_files), " PDF(s) older than 90 days")
    file.remove(old_files)
  }
}

# Step 1: Download and text parse the PDFs

if (nrow(needed_files) > 0) {
   new_files <- needed_files
   new_files$Text <- ""
   pdf_text_safely <- purrr::possibly(pdftools::pdf_text, otherwise = "")

  for (i in 1:nrow(new_files)) {
    download.file(new_files$item_link[i], destfile = glue("data/{new_files$File[i]}"), quiet = TRUE, mode = "wb")
    all_text <- pdf_text_safely(glue("data/{new_files$File[i]}"))
    all_text <- stringr::str_squish(all_text)
    all_text_merged <- paste(all_text, collapse = "\n\n")
    new_files$Text[i] <- all_text_merged

    # Create a data frame of extracted Item, Address, Board, MeetingDate

  }

  new_files$Board <- stringr::str_squish(new_files$Board)
  new_files$Meeting <- stringr::str_squish(new_files$Meeting)
  # Save interim new_files with just the text
  rio::export(new_files, "interim_latest_files_w_text.parquet")
} else {
  print("No new meeting files needed to download")
}


# Step 2 if there are new files, extract Board, Date, Description, Address
if(exists("new_files")) {

  # Define object type for a hearing item
  type_hearing_item <- type_object(
    description = type_string("Short description of the hearing item"),
    address = type_string("Address where the hearing will take place", required = FALSE)
  )

  type_hearings <- type_array(
    type_hearing_item,
    description = "Array of all hearing items found in the text. Extract only items that are clearly part of hearings, there will be other info in the text."
  )

  chat <- chat_openai(model = "gpt-4.1", system_prompt = "You are adept at extracting structured data such as descriptions and addresses from public meeting agenda. You do this for public hearing items and licensing hearing items.")

  temp_results <- new_files %>%
  rowwise() %>%
  mutate(
    extracted_hearings = list(
      chat$chat_structured(
        paste("Extract all hearing items from the following agenda text:", Text),
        type = type_hearings
      )
    )
  ) %>%
  ungroup()

  hearings_df <- temp_results %>%
  select(Date, Board, URL, extracted_hearings) %>%
  tidyr::unnest(extracted_hearings)
}

# Step 3: Geocode the addresses and get the districts
if(exists("hearings_df")) {

  # Add ", Framingham, MA" to addresses that don't already contain "Framingham" and make sure "Old Conn Path" is turned into "Old Connecticut Path"
  hearings_df <- hearings_df %>%
    mutate(
      # Fix abbreviated street names
      address = str_replace(address, regex("Old Conn Path", ignore_case = TRUE), "Old Connecticut Path"),
      # Add city/state if not present
      address_full = if_else(
        str_detect(address, regex("Framingham", ignore_case = TRUE)),
        address,
        paste0(address, ", Framingham, MA")
      )
    )

  # Geocode using Geocodio
  # Note: Set your Geocodio API key with Sys.setenv(GEOCODIO_API_KEY = "your_key")
  hearings_geocoded <- hearings_df %>%
    geocode(
      address = address_full,
      method = "geocodio",
      lat = latitude,
      long = longitude
    )

  # Check for failed geocodes
  failed_geocodes <- hearings_geocoded %>%
    filter(is.na(latitude) | is.na(longitude))

  if (nrow(failed_geocodes) > 0) {
    message("Warning: ", nrow(failed_geocodes), " addresses failed to geocode")
    print(failed_geocodes %>% select(address, address_full))
  }

  # Load district shapefile
  framingham_gis <- sf::st_read("gis/framingham_districts.shp", quiet = TRUE)

  # Convert geocoded results to sf object and get districts
  hearings_with_districts <- hearings_geocoded %>%
    filter(!is.na(latitude) & !is.na(longitude)) %>%
    sf::st_as_sf(coords = c("longitude", "latitude"), crs = 4326) %>%
    sf::st_join(framingham_gis, join = sf::st_within) %>%
    sf::st_drop_geometry()  # Remove geometry column to return to regular data frame

  # Add back any rows that failed to geocode (with NA for District)
  if (nrow(failed_geocodes) > 0) {
    failed_geocodes$District <- NA_character_
    hearings_with_districts <- bind_rows(hearings_with_districts, failed_geocodes)
  }

  # Save new results
  saveRDS(hearings_with_districts, "new_hearings_with_districts.Rds")
  message("Geocoded and matched ", nrow(hearings_with_districts), " new hearing items to districts")

  # Combine with existing data if it exists
  if (file.exists("hearings_with_districts.Rds")) {
    existing_hearings <- readRDS("hearings_with_districts.Rds")
    all_hearings <- bind_rows(existing_hearings, hearings_with_districts)
    message("Combined ", nrow(existing_hearings), " existing + ", nrow(hearings_with_districts),
            " new = ", nrow(all_hearings), " total hearings")
  } else {
    all_hearings <- hearings_with_districts
    message("No existing data found, creating new hearings_with_districts.Rds")
  }

  # Save combined results
  saveRDS(all_hearings, "hearings_with_districts.Rds")

  all_hearings <- readRDS("hearings_with_districts.Rds")
  all_hearings <- all_hearings |>
    filter(!stringr::str_detect(URL, "2605$|2563$"))
  saveRDS(all_hearings, "hearings_with_districts.Rds")
  # saveRDS(dupes, "deleted_dupes.Rds")
  # get rid of 2605 and either 2563 or 4973



  # Send email uncomment this
  # source("send_email.R")
}
