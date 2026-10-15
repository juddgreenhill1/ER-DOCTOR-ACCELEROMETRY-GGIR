# ============================================================
# MASTER SCRIPT 2 of 4: Sleep / Nap flagging using the manual sleep log
#
# Works for any participant who follows the folder/file convention
# described in the repository README (same layout as S15).
#
# >>> THE ONLY LINE YOU SHOULD NEED TO CHANGE (for interactive/RStudio use): <<<
PARTICIPANT_ID <- "S15"
# >>> ------------------------------------------ <<<
#
# When run from the command line (e.g. Rscript in a terminal), this
# value is overridden by a command-line argument instead:
#   Rscript master_02_flag_sleep_naps.R <PARTICIPANT_ID>
.args <- commandArgs(trailingOnly = TRUE)
if (length(.args) >= 1 && nzchar(.args[1])) PARTICIPANT_ID <- .args[1]
#
# Reads master_01's one-minute GGIR output and the manual sleep/nap
# interval file, marks every one-minute row as main_sleep / nap / waking,
# and computes PA category + MVPA using ONLY valid, waking minutes.
#
# NOTE ON TIMESTAMPS:
# The "timestamp" column in master_01's output is already a proper
# POSIXct/UTC value -- do NOT reparse it with ymd_hms()/parse_date_time().
# It only needs with_tz() to convert it to local South African time.
#
# The interval CSV's start_datetime/end_datetime columns ARE plain
# character strings and DO need explicit parsing -- read them as text
# and parse with a FIXED format (as.POSIXct(..., format = "%Y-%m-%d %H:%M:%S"))
# rather than a "smart"/guessing parser. A guessing parser (ymd_hms(),
# or read_csv()'s auto column-type detection) can behave inconsistently
# on a column that is mostly timed values plus the occasional exact-
# midnight value -- that produced real, hard-to-diagnose failures during
# S15's setup. Explicit format = zero guessing = reproducible for every
# future participant.
# ============================================================

required_packages <- c("tidyverse", "lubridate")
missing_packages <- required_packages[!required_packages %in% rownames(installed.packages())]
if (length(missing_packages) > 0) install.packages(missing_packages)

library(tidyverse)
library(lubridate)

# Root folder holding one sub-folder per participant (see README).
# Set the FINAL_ER_ROOT environment variable, or edit the fallback path.
final_er_root <- Sys.getenv("FINAL_ER_ROOT", unset = "path/to/FINAL_ER")
tz_sast        <- "Africa/Johannesburg"

project_dir    <- file.path(final_er_root, PARTICIPANT_ID)
clean_dir      <- file.path(project_dir, "output", "clean_csv")
intervals_file <- file.path(project_dir, "sleep_log", paste0(PARTICIPANT_ID, "_sleep_nap_intervals_for_flagging.csv"))
output_file    <- file.path(clean_dir, paste0(PARTICIPANT_ID, "_clean_1min_sleep_naps_flagged.csv"))


# ------------------------------------------------------------
# 0. Auto-detect master_01's output file (its name depends on the raw
#    .bin filename, e.g. s15_T5A5_1min_all.csv, so we search rather than
#    hardcode it)
# ------------------------------------------------------------

candidate_files <- list.files(clean_dir, pattern = "_1min_all\\.csv$", full.names = TRUE)

if (length(candidate_files) == 0) {
  stop(
    "[", PARTICIPANT_ID, "] no '*_1min_all.csv' file found in ", clean_dir,
    " -- run master_01_ggir.R first."
  )
}
if (length(candidate_files) > 1) {
  candidate_files <- candidate_files[order(file.info(candidate_files)$mtime, decreasing = TRUE)]
  warning(
    "[", PARTICIPANT_ID, "] multiple '*_1min_all.csv' files found in ", clean_dir,
    " -- using the most recently modified: ", basename(candidate_files[1])
  )
}
minute_file <- candidate_files[1]

if (!file.exists(intervals_file)) {
  stop(
    "[", PARTICIPANT_ID, "] sleep/nap interval file not found: ", intervals_file,
    ". Expected filename: ", PARTICIPANT_ID, "_sleep_nap_intervals_for_flagging.csv ",
    "inside the sleep_log/ folder."
  )
}


# ------------------------------------------------------------
# 1. Read and parse the manual sleep/nap interval file
# ------------------------------------------------------------

intervals <- read_csv(
  intervals_file,
  show_col_types = FALSE,
  col_types = cols(
    start_datetime = col_character(),
    end_datetime   = col_character(),
    .default = col_guess()
  )
) %>%
  mutate(
    participant_id = as.character(participant_id),
    interval_type  = str_to_lower(str_trim(interval_type)),
    start_datetime = as.POSIXct(start_datetime, format = "%Y-%m-%d %H:%M:%S", tz = tz_sast),
    end_datetime   = as.POSIXct(end_datetime,   format = "%Y-%m-%d %H:%M:%S", tz = tz_sast)
  )

bad_parse <- intervals %>% filter(is.na(start_datetime) | is.na(end_datetime))
if (nrow(bad_parse) > 0) {
  print(bad_parse)
  stop(
    "[", PARTICIPANT_ID, "] one or more rows in ", basename(intervals_file),
    " failed to parse start_datetime/end_datetime. Fix these rows and re-run."
  )
}

bad_type <- intervals %>% filter(!interval_type %in% c("sleep", "nap"))
if (nrow(bad_type) > 0) {
  print(bad_type)
  stop("[", PARTICIPANT_ID, "] interval_type must be 'sleep' or 'nap' for every row. See rows above.")
}

bad_order <- intervals %>% filter(end_datetime <= start_datetime)
if (nrow(bad_order) > 0) {
  print(bad_order)
  stop("[", PARTICIPANT_ID, "] one or more intervals have end_datetime <= start_datetime. Fix and re-run.")
}

sleep_intervals <- intervals %>% filter(interval_type == "sleep")
nap_intervals   <- intervals %>% filter(interval_type == "nap")

message(
  "[", PARTICIPANT_ID, "] Loaded ", nrow(sleep_intervals), " sleep interval(s) and ",
  nrow(nap_intervals), " nap interval(s)."
)


# ------------------------------------------------------------
# 2. Read master_01's one-minute GGIR file
# ------------------------------------------------------------

minute_data <- read_csv(minute_file, show_col_types = FALSE)

required_cols <- c("timestamp", "ENMO_mg", "valid_minute")
missing_cols  <- setdiff(required_cols, names(minute_data))
if (length(missing_cols) > 0) {
  stop(
    "[", PARTICIPANT_ID, "] missing required column(s) in ", basename(minute_file), ": ",
    paste(missing_cols, collapse = ", ")
  )
}

if (!inherits(minute_data$timestamp, "POSIXct")) {
  stop(
    "[", PARTICIPANT_ID, "] 'timestamp' was not parsed as a date-time by read_csv(). ",
    "This script assumes it already is POSIXct (as produced by master_01)."
  )
}

minute_data <- minute_data %>%
  mutate(
    participant_id = PARTICIPANT_ID,
    local_datetime = with_tz(timestamp, tz_sast)
  )


# ------------------------------------------------------------
# 3. Flag main_sleep / nap using the manual interval file
#    (vectorized interval membership -- fast and avoids row-by-row
#    map_lgl() over every interval)
# ------------------------------------------------------------

flag_intervals <- function(dt, ivals) {
  if (nrow(ivals) == 0) return(rep(FALSE, length(dt)))
  hit <- outer(dt, ivals$start_datetime, `>=`) &
         outer(dt, ivals$end_datetime,   `<`)
  rowSums(hit) > 0
}

minute_data <- minute_data %>%
  mutate(
    main_sleep = flag_intervals(local_datetime, sleep_intervals),
    nap        = flag_intervals(local_datetime, nap_intervals),
    waking     = !main_sleep & !nap,

    include_in_PA_analysis = valid_minute & waking & !is.na(ENMO_mg),

    # ------------------------------------------------------------
    # Manual ENMO thresholds (mg):
    #   Sedentary < 36 | Light 36-<92 | Moderate 92-<283 | Vigorous >=283
    # NA for excluded minutes (sleep, nap, invalid, or non-waking).
    # ------------------------------------------------------------
    activity_intensity = case_when(
      !include_in_PA_analysis ~ NA_character_,
      ENMO_mg < 36   ~ "Sedentary",
      ENMO_mg < 92   ~ "Light",
      ENMO_mg < 283  ~ "Moderate",
      ENMO_mg >= 283 ~ "Vigorous"
    ),

    MVPA = include_in_PA_analysis &
      activity_intensity %in% c("Moderate", "Vigorous"),

    sleep_nap_wake = case_when(
      main_sleep ~ "Sleep",
      nap        ~ "Nap",
      waking     ~ "Wake",
      TRUE ~ NA_character_
    ),

    # tz must be specified here -- as.Date() on a POSIXct object defaults to
    # extracting the calendar date in UTC regardless of the object's own
    # tzone attribute. Without this, minutes between 00:00-01:59:59 SAST
    # (still the previous day in UTC) get silently mislabeled onto the
    # previous calendar date.
    date          = as.Date(local_datetime, tz = tz_sast),
    time          = format(local_datetime, "%H:%M:%S"),
    datetime_SAST = format(local_datetime, "%Y-%m-%d %H:%M:%S")
  )

double_flagged <- sum(minute_data$main_sleep & minute_data$nap)
if (double_flagged > 0) {
  warning(
    "[", PARTICIPANT_ID, "] ", double_flagged,
    " minute(s) fall inside BOTH a sleep interval and a nap interval. ",
    "Check for overlapping rows in ", basename(intervals_file), "."
  )
}


# ------------------------------------------------------------
# 4. Column order and save
# ------------------------------------------------------------

first_columns <- c(
  "participant_id", "datetime_SAST", "date", "time", "timestamp",
  "ENMO_mg", "valid_minute",
  "main_sleep", "nap", "waking", "sleep_nap_wake",
  "include_in_PA_analysis", "activity_intensity", "MVPA"
)

minute_data <- minute_data %>%
  select(all_of(first_columns), everything(), -local_datetime)

write_csv(minute_data, output_file, na = "")
message("[", PARTICIPANT_ID, "] Created: ", output_file)


# ------------------------------------------------------------
# 5. Summary for verification
# ------------------------------------------------------------

minute_data %>%
  summarise(
    total_minutes        = n(),
    valid_minutes        = sum(valid_minute, na.rm = TRUE),
    sleep_minutes         = sum(main_sleep, na.rm = TRUE),
    nap_minutes           = sum(nap, na.rm = TRUE),
    wake_minutes          = sum(waking, na.rm = TRUE),
    included_PA_minutes   = sum(include_in_PA_analysis, na.rm = TRUE)
  ) %>%
  print()

minute_data %>%
  filter(include_in_PA_analysis) %>%
  count(activity_intensity) %>%
  print()

message("[", PARTICIPANT_ID, "] Done. Next: master_03_attach_shift.R")
