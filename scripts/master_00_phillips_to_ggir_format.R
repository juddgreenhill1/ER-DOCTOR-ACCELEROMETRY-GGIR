# ============================================================
# MASTER SCRIPT 0 (pre-step): Convert Phillips export -> GGIR-format inputs
#
# Takes the raw two-sheet Phillips export ("{ID}" + "{ID} Work Diary")
# and produces the three standardized files master_01-04 expect:
#   sleep_log/{ID}_GGIR_sleep_log.csv
#   sleep_log/{ID}_sleep_nap_intervals_for_flagging.csv
#   shift_log/{ID}_shift_log.csv
#
# Expected source file: {ID}/Phillips SleepLog/{ID}.xlsx (any .xlsx whose
# name starts with the participant ID is accepted)
#
# >>> THE TWO LINES YOU SHOULD NEED TO CHANGE (for interactive/RStudio use): <<<
PARTICIPANT_ID <- "S15"
EXPECTED_YEAR  <- 2025
# >>> ------------------------------------------------------- <<<
#
# When run from the command line (e.g. Rscript in a terminal), these
# two values are overridden by command-line arguments instead:
#   Rscript master_00_phillips_to_ggir_format.R <PARTICIPANT_ID> <EXPECTED_YEAR>
.args <- commandArgs(trailingOnly = TRUE)
if (length(.args) >= 1 && nzchar(.args[1])) PARTICIPANT_ID <- .args[1]
if (length(.args) >= 2 && nzchar(.args[2])) EXPECTED_YEAR  <- as.numeric(.args[2])
#
# Why EXPECTED_YEAR exists: the Phillips export usually gets the year
# right, but occasionally mis-enters it on individual rows (seen on S15:
# Diary Date correctly read 2025-09-30, but the Shift Start Date on that
# same row read 2026-09-30). This script forces every date field to
# EXPECTED_YEAR and PRINTS every row it had to correct, so nothing is
# silently rewritten -- check the "Year corrections made" output below
# before trusting the result.
#
# LIMITATION: this assumes the participant's whole recording falls in one
# calendar year. If a participant's data genuinely spans a New Year (e.g.
# starts late Dec, continues into Jan), this simple approach is wrong --
# stop and handle that case by hand rather than running this as-is.
#
# Column mapping (confirmed against S15's workbook, same structure for every
# participant):
#   Sheet "{ID}":
#     Main/nap        -> phillips_label / interval_type ("Sleep" -> sleep,
#                         "NapOn"/"NapOff" -> nap -- both just mean a nap,
#                         NapOn = napped while on shift, NapOff = napped
#                         off shift; no distinction needed downstream)
#     Interval#       -> interval_id
#     S Start Date/Time, S End Date/Time  -> the SCORED SLEEP period
#                         (NOT the "R Rest Period" columns, which are a
#                         different, wider window)
#   Sheet "{ID} Work Diary":
#     Day             -> used to build shift_id
#     Type            -> shift_type
#     Shift Start Date/Time, Shift End date/Time -> shift start/end
# ============================================================

required_packages <- c("tidyverse", "lubridate", "readxl")
missing_packages <- required_packages[!required_packages %in% rownames(installed.packages())]
if (length(missing_packages) > 0) install.packages(missing_packages)

library(tidyverse)
library(lubridate)
library(readxl)

# Root folder holding one sub-folder per participant (see README).
# Set the FINAL_ER_ROOT environment variable, or edit the fallback path.
final_er_root <- Sys.getenv("FINAL_ER_ROOT", unset = "path/to/FINAL_ER")
project_dir   <- file.path(final_er_root, PARTICIPANT_ID)

# The workbook is any .xlsx in the diary folder whose name starts with the
# participant ID (e.g. S15.xlsx or S15_diary.xlsx). The ID must not be
# followed by another digit, so S1 does not pick up S15's file.
diary_dir    <- file.path(project_dir, "Phillips SleepLog")
source_files <- list.files(
  diary_dir,
  pattern = paste0("^", PARTICIPANT_ID, "([^0-9].*)?\\.xlsx$"),
  full.names = TRUE, ignore.case = TRUE
)
source_files <- source_files[!startsWith(basename(source_files), "~$")]  # skip Excel lock files
if (length(source_files) != 1) {
  stop(
    "[", PARTICIPANT_ID, "] expected exactly one diary workbook in ", diary_dir,
    " named {ID}*.xlsx -- found ", length(source_files),
    if (length(source_files) > 0) paste0(": ", paste(basename(source_files), collapse = ", ")) else ""
  )
}
source_file <- source_files[1]

sleep_log_out  <- file.path(project_dir, "sleep_log", paste0(PARTICIPANT_ID, "_GGIR_sleep_log.csv"))
interval_out   <- file.path(project_dir, "sleep_log", paste0(PARTICIPANT_ID, "_sleep_nap_intervals_for_flagging.csv"))
shift_log_out  <- file.path(project_dir, "shift_log", paste0(PARTICIPANT_ID, "_shift_log.csv"))

dir.create(dirname(sleep_log_out), recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(shift_log_out), recursive = TRUE, showWarnings = FALSE)


# ------------------------------------------------------------
# Helper: force a date/datetime vector to EXPECTED_YEAR, report what changed
# ------------------------------------------------------------

correct_year <- function(dates, expected_year, field_label) {
  original <- dates
  corrected <- dates
  ok <- !is.na(dates)
  if (any(ok)) year(corrected)[ok] <- expected_year
  changed <- !is.na(original) & (as.Date(original) != as.Date(corrected))
  if (any(changed)) {
    message(
      "  [", field_label, "] corrected ", sum(changed), " row(s): ",
      paste0(as.character(original[changed]), " -> ", as.character(corrected[changed]), collapse = "; ")
    )
  }
  corrected
}


# ------------------------------------------------------------
# Helpers for reading a sheet with col_types = "list" -- this reads every
# cell at its OWN native type instead of guessing one type for the whole
# column. That matters here because some Off-day rows put a literal "-" in
# the Shift Start/End Date cells (not just the time cells) -- if the column
# is read with a single guessed type, mixing real dates with that text can
# make the whole column fail to parse as dates. Reading cell-by-cell lets
# us treat "-" (or any other non-date text) as simply missing, per row,
# without losing the real dates elsewhere in the same column.
# ------------------------------------------------------------

cell_to_date <- function(x) {
  if (is.null(x) || length(x) == 0 || (length(x) == 1 && is.na(x))) return(as.Date(NA))
  if (inherits(x, "POSIXct") || inherits(x, "Date")) return(as.Date(x))
  if (is.numeric(x)) return(as.Date(x, origin = "1899-12-30"))
  as.Date(NA)  # text placeholders like "-" -> missing, not an error
}

cell_to_time <- function(x) {
  if (is.null(x) || length(x) == 0 || (length(x) == 1 && is.na(x))) return(NA_character_)
  if (inherits(x, "POSIXct")) return(format(x, "%H:%M:%S"))
  if (is.numeric(x)) {
    secs <- round(x * 86400) %% 86400
    return(sprintf("%02d:%02d:%02d", secs %/% 3600, (secs %% 3600) %/% 60, secs %% 60))
  }
  NA_character_
}

cell_to_chr <- function(x) {
  if (is.null(x) || length(x) == 0 || (length(x) == 1 && is.na(x))) return(NA_character_)
  as.character(x)
}

cell_to_num <- function(x) {
  if (is.null(x) || length(x) == 0 || (length(x) == 1 && is.na(x))) return(NA_real_)
  suppressWarnings(as.numeric(x))
}

extract_date_col <- function(list_col) as.Date(vapply(list_col, function(x) as.numeric(cell_to_date(x)), numeric(1)), origin = "1970-01-01")
extract_time_col <- function(list_col) vapply(list_col, cell_to_time, character(1))
extract_chr_col  <- function(list_col) vapply(list_col, cell_to_chr, character(1))
extract_num_col  <- function(list_col) vapply(list_col, cell_to_num, numeric(1))


# ------------------------------------------------------------
# Helper: locate the real header row instead of assuming a fixed number of
# title/label rows above it. S15's sheets happened to have exactly 2 (sleep)
# and 3 (diary) rows above the real headers, but that count is NOT the same
# for every participant's Phillips export -- for S29 the Work Diary sheet
# had one fewer row than S15's, so a fixed skip=3 grabbed a DATA row as the
# header row instead (that's why the error showed date serials and shift
# names like "Swing"/"Chronics" as column names -- those were real data
# values readxl was forced to treat as header text).
#
# This scans the first few rows of the sheet for the row that actually
# contains the expected header text, and reads from there -- works
# regardless of how many title/label rows a given participant's file has.
# ------------------------------------------------------------

find_header_row <- function(source_file, sheet_name, marker_columns, max_scan_rows = 10) {
  probe <- read_excel(
    source_file, sheet = sheet_name, col_names = FALSE,
    n_max = max_scan_rows, col_types = "text"
  )
  for (i in seq_len(nrow(probe))) {
    row_values <- str_trim(as.character(unlist(probe[i, ])))
    if (all(marker_columns %in% row_values)) {
      return(i)
    }
  }
  stop(
    "[", PARTICIPANT_ID, "] could not locate the header row in sheet '", sheet_name,
    "' -- looked for a row containing all of: ", paste(marker_columns, collapse = ", "),
    " within the first ", max_scan_rows, " rows. The sheet layout may differ from what",
    " this script expects -- check it by hand."
  )
}


# ------------------------------------------------------------
# 1. Read the sleep/nap sheet
#    Header row is auto-detected (see find_header_row() above) rather than
#    assuming a fixed number of title/label rows.
# ------------------------------------------------------------

sleep_header_row <- find_header_row(source_file, PARTICIPANT_ID, c("Main/nap", "Interval#"))
sleep_list <- read_excel(source_file, sheet = PARTICIPANT_ID, skip = sleep_header_row - 1, col_types = "list")

required_sleep_cols <- c("Main/nap", "Interval#", "S Start Date", "S Start Time", "S End Date", "S End Time")
missing_sleep_cols <- setdiff(required_sleep_cols, names(sleep_list))
if (length(missing_sleep_cols) > 0) {
  stop(
    "[", PARTICIPANT_ID, "] expected column(s) not found in sheet '", PARTICIPANT_ID, "': ",
    paste(missing_sleep_cols, collapse = ", "),
    "\nFound columns: ", paste(names(sleep_list), collapse = ", ")
  )
}

sleep_raw <- tibble(
  phillips_label = extract_chr_col(sleep_list[["Main/nap"]]),
  interval_id    = extract_num_col(sleep_list[["Interval#"]]),
  s_start_date   = extract_date_col(sleep_list[["S Start Date"]]),
  s_start_time   = extract_time_col(sleep_list[["S Start Time"]]),
  s_end_date     = extract_date_col(sleep_list[["S End Date"]]),
  s_end_time     = extract_time_col(sleep_list[["S End Time"]])
) %>%
  filter(!is.na(phillips_label))

allowed_labels <- c("Sleep", "NapOn", "NapOff")
bad_labels <- sleep_raw %>% filter(!phillips_label %in% allowed_labels)
if (nrow(bad_labels) > 0) {
  print(bad_labels)
  stop(
    "[", PARTICIPANT_ID, "] found Main/nap label(s) other than Sleep/NapOn/NapOff (see rows above). ",
    "This script only knows how to handle those three -- check the source file."
  )
}

message("[", PARTICIPANT_ID, "] Year corrections made (sleep/nap sheet):")
sleep_raw <- sleep_raw %>%
  mutate(
    s_start_date = correct_year(s_start_date, EXPECTED_YEAR, "S Start Date"),
    s_end_date   = correct_year(s_end_date,   EXPECTED_YEAR, "S End Date")
  )

sleep_raw <- sleep_raw %>%
  mutate(
    interval_type   = if_else(phillips_label == "Sleep", "sleep", "nap"),
    start_datetime  = as.POSIXct(
      paste(format(s_start_date, "%Y-%m-%d"), s_start_time),
      format = "%Y-%m-%d %H:%M:%S", tz = "Africa/Johannesburg"
    ),
    end_datetime    = as.POSIXct(
      paste(format(s_end_date, "%Y-%m-%d"), s_end_time),
      format = "%Y-%m-%d %H:%M:%S", tz = "Africa/Johannesburg"
    )
  ) %>%
  arrange(interval_id)

bad_order <- sleep_raw %>% filter(end_datetime <= start_datetime | is.na(start_datetime) | is.na(end_datetime))
if (nrow(bad_order) > 0) {
  print(bad_order %>% select(interval_id, phillips_label, start_datetime, end_datetime))
  stop(
    "[", PARTICIPANT_ID, "] one or more sleep/nap rows have an invalid or missing start/end datetime ",
    "even after year correction. Fix these in the source file (or reconsider EXPECTED_YEAR) before continuing."
  )
}


# ------------------------------------------------------------
# 2. Build the combined sleep+nap interval CSV
# ------------------------------------------------------------

interval_csv <- sleep_raw %>%
  transmute(
    participant_id = PARTICIPANT_ID,
    interval_id,
    interval_type,
    phillips_label,
    start_datetime = format(start_datetime, "%Y-%m-%d %H:%M:%S"),
    end_datetime   = format(end_datetime, "%Y-%m-%d %H:%M:%S")
  )

write_csv(interval_csv, interval_out, na = "")
message(
  "[", PARTICIPANT_ID, "] Created: ", interval_out, " (",
  sum(sleep_raw$interval_type == "sleep"), " sleep, ",
  sum(sleep_raw$interval_type == "nap"), " nap intervals)"
)


# ------------------------------------------------------------
# 3. Build the basic GGIR sleep log (main sleep only, one row, wide format)
# ------------------------------------------------------------

main_sleep_rows <- sleep_raw %>% filter(interval_type == "sleep") %>% arrange(interval_id)
n_nights <- nrow(main_sleep_rows)

onset  <- format(main_sleep_rows$start_datetime, "%H:%M:%S")
wakeup <- format(main_sleep_rows$end_datetime, "%H:%M:%S")

interleaved <- character(2 * n_nights)
interleaved[seq(1, 2 * n_nights, by = 2)] <- onset
interleaved[seq(2, 2 * n_nights, by = 2)] <- wakeup

col_names <- character(2 * n_nights)
col_names[seq(1, 2 * n_nights, by = 2)] <- paste0("onset_N", seq_len(n_nights))
col_names[seq(2, 2 * n_nights, by = 2)] <- paste0("wakeup_N", seq_len(n_nights))

ggir_sleep_log <- as_tibble(
  setNames(as.list(c(PARTICIPANT_ID, interleaved)), c("ID", col_names))
)

write_csv(ggir_sleep_log, sleep_log_out, na = "")
message("[", PARTICIPANT_ID, "] Created: ", sleep_log_out, " (", n_nights, " main-sleep nights)")


# ------------------------------------------------------------
# 4. Read the Work Diary sheet and build the shift log
#    Header row is auto-detected (see find_header_row() above) rather than
#    assuming a fixed number of title/label rows.
# ------------------------------------------------------------

diary_header_row <- find_header_row(source_file, paste0(PARTICIPANT_ID, " Work Diary"), c("Day", "Type"))
diary_list <- read_excel(source_file, sheet = paste0(PARTICIPANT_ID, " Work Diary"), skip = diary_header_row - 1, col_types = "list")

required_diary_cols <- c("Day", "Diary Date", "Type", "Shift Start Date", "Shift Start Time")
missing_diary_cols <- setdiff(required_diary_cols, names(diary_list))
if (length(missing_diary_cols) > 0) {
  stop(
    "[", PARTICIPANT_ID, "] expected column(s) not found in the Work Diary sheet: ",
    paste(missing_diary_cols, collapse = ", "),
    "\nFound columns: ", paste(names(diary_list), collapse = ", ")
  )
}

# "Shift End date" has a lower-case 'd' in the source file -- match
# case-insensitively so a stray capitalization difference doesn't break this.
end_date_col <- names(diary_list)[str_to_lower(str_trim(names(diary_list))) == "shift end date"]
if (length(end_date_col) != 1) {
  stop(
    "[", PARTICIPANT_ID, "] could not find a unique 'Shift End date' column. Found: ",
    paste(names(diary_list), collapse = ", ")
  )
}

diary_raw <- tibble(
  Day                  = extract_num_col(diary_list[["Day"]]),
  diary_date           = extract_date_col(diary_list[["Diary Date"]]),
  Type                 = extract_chr_col(diary_list[["Type"]]),
  shift_start_date_raw = extract_date_col(diary_list[["Shift Start Date"]]),
  shift_end_date_raw   = extract_date_col(diary_list[[end_date_col]]),
  start_time_raw       = extract_time_col(diary_list[["Shift Start Time"]]),
  end_time_raw         = extract_time_col(diary_list[["Shift End Time"]])
) %>%
  filter(!is.na(Day))

message("[", PARTICIPANT_ID, "] Year corrections made (work diary sheet):")
diary_raw <- diary_raw %>%
  mutate(
    diary_date           = correct_year(diary_date, EXPECTED_YEAR, "Diary Date"),
    shift_start_date_raw = correct_year(shift_start_date_raw, EXPECTED_YEAR, "Shift Start Date"),
    shift_end_date_raw   = correct_year(shift_end_date_raw,   EXPECTED_YEAR, "Shift End date")
  )

# Off/Postcall-style rows sometimes have a literal "-" placeholder in the
# Shift Start/End Date cells themselves (not just the time cells), which
# reads as missing. These are single-day entries, so the Diary Date is a
# reliable stand-in for both the start and end date in that case.
missing_start <- is.na(diary_raw$shift_start_date_raw)
missing_end   <- is.na(diary_raw$shift_end_date_raw)
if (any(missing_start) || any(missing_end)) {
  message(
    "  Filled ", sum(missing_start), " missing Shift Start Date and ", sum(missing_end),
    " missing Shift End date value(s) from that row's Diary Date (Day: ",
    paste(diary_raw$Day[missing_start | missing_end], collapse = ", "), ")."
  )
}
diary_raw$shift_start_date_raw[missing_start] <- diary_raw$diary_date[missing_start]
diary_raw$shift_end_date_raw[missing_end]     <- diary_raw$diary_date[missing_end]

shift_log_csv <- diary_raw %>%
  arrange(Day) %>%
  transmute(
    participant_id   = PARTICIPANT_ID,
    shift_id         = paste0(PARTICIPANT_ID, "_", sprintf("%02d", Day)),
    shift_type       = Type,
    shift_start_date = format(shift_start_date_raw, "%Y-%m-%d"),
    shift_end_date   = format(shift_end_date_raw, "%Y-%m-%d"),
    start_time       = start_time_raw,
    end_time         = end_time_raw
  )

bad_shift_dates <- shift_log_csv %>% filter(is.na(shift_start_date) | is.na(shift_end_date))
if (nrow(bad_shift_dates) > 0) {
  print(bad_shift_dates)
  stop("[", PARTICIPANT_ID, "] one or more shift rows are missing a start/end date. Fix and re-run.")
}

write_csv(shift_log_csv, shift_log_out, na = "")
message("[", PARTICIPANT_ID, "] Created: ", shift_log_out, " (", nrow(shift_log_csv), " shift rows)")

message(
  "[", PARTICIPANT_ID, "] Conversion complete. Review the year-correction messages above, ",
  "then run master_01_ggir.R."
)
