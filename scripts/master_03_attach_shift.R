# ============================================================
# MASTER SCRIPT 3 of 4: Attach shift type to the flagged one-minute data
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
#   Rscript master_03_attach_shift.R <PARTICIPANT_ID>
.args <- commandArgs(trailingOnly = TRUE)
if (length(.args) >= 1 && nzchar(.args[1])) PARTICIPANT_ID <- .args[1]
#
# Joins each one-minute row to the shift diary using a proper
# datetime-interval match (shift_start_date + start_time through
# shift_end_date + end_time), NOT a date-only match -- a date-only match
# mis-assigns every night shift's post-midnight minutes, since those
# minutes' calendar date is the day AFTER shift_start_date.
#
# Off / Postcall-style rows (no start_time/end_time) are treated as a
# full-calendar-day default. If an explicit-timed row overlaps into that
# same day (e.g. a Night shift starting that evening), the explicit-timed
# row takes priority for those minutes, and the full-day default only
# fills in the remaining, uncovered hours.
#
# If the shift log has a hospital_site column, it's carried through into
# the output. If not, Hospital is left blank.
# ============================================================

required_packages <- c("tidyverse", "lubridate")
missing_packages <- required_packages[!required_packages %in% rownames(installed.packages())]
if (length(missing_packages) > 0) install.packages(missing_packages)

library(tidyverse)
library(lubridate)

# Root folder holding one sub-folder per participant (see README).
# Set the FINAL_ER_ROOT environment variable, or edit the fallback path.
final_er_root <- Sys.getenv("FINAL_ER_ROOT", unset = "path/to/FINAL_ER")
tz_sast       <- "Africa/Johannesburg"

project_dir <- file.path(final_er_root, PARTICIPANT_ID)
clean_file  <- file.path(project_dir, "output", "clean_csv", paste0(PARTICIPANT_ID, "_clean_1min_sleep_naps_flagged.csv"))
shift_file  <- file.path(project_dir, "shift_log", paste0(PARTICIPANT_ID, "_shift_log.csv"))
output_file <- file.path(project_dir, "output", paste0(PARTICIPANT_ID, "_clean_1min_with_shift.csv"))

if (!file.exists(clean_file)) {
  stop("[", PARTICIPANT_ID, "] master_02 output not found: ", clean_file, " -- run master_02_flag_sleep_naps.R first.")
}
if (!file.exists(shift_file)) {
  stop("[", PARTICIPANT_ID, "] shift log not found: ", shift_file)
}


# ------------------------------------------------------------
# 1. Read the flagged one-minute data
# ------------------------------------------------------------

clean <- read_csv(
  clean_file,
  show_col_types = FALSE,
  col_types = cols(datetime_SAST = col_character(), .default = col_guess())
) %>%
  mutate(
    participant_id = PARTICIPANT_ID,
    local_datetime = as.POSIXct(datetime_SAST, format = "%Y-%m-%d %H:%M:%S", tz = tz_sast)
  )


# ------------------------------------------------------------
# 2. Read and prepare the shift log (comma-delimited)
# ------------------------------------------------------------

shift_log <- read_csv(
  shift_file,
  show_col_types = FALSE,
  col_types = cols(
    shift_start_date = col_character(),
    shift_end_date   = col_character(),
    start_time       = col_character(),
    end_time         = col_character(),
    .default = col_guess()
  )
) %>%
  mutate(
    participant_id     = as.character(participant_id),
    shift_start_date    = as.Date(shift_start_date, format = "%Y-%m-%d"),
    shift_end_date      = as.Date(shift_end_date,   format = "%Y-%m-%d"),
    has_explicit_times  = !is.na(start_time) & !is.na(end_time) &
      str_trim(start_time) != "" & str_trim(end_time) != ""
  )

has_hospital_col <- "hospital_site" %in% names(shift_log)
if (!has_hospital_col) {
  shift_log$hospital_site <- NA_character_
}

duplicate_ids <- shift_log %>% count(shift_id) %>% filter(n > 1)
if (nrow(duplicate_ids) > 0) {
  print(duplicate_ids)
  stop("[", PARTICIPANT_ID, "] the shift log has duplicate shift_id values. Fix before continuing.")
}

shift_log <- shift_log %>%
  mutate(
    shift_start_datetime = if_else(
      has_explicit_times,
      as.POSIXct(paste(shift_start_date, start_time), format = "%Y-%m-%d %H:%M:%S", tz = tz_sast),
      as.POSIXct(paste(shift_start_date, "00:00:00"), format = "%Y-%m-%d %H:%M:%S", tz = tz_sast)
    ),
    shift_end_datetime = if_else(
      has_explicit_times,
      as.POSIXct(paste(shift_end_date, end_time), format = "%Y-%m-%d %H:%M:%S", tz = tz_sast),
      as.POSIXct(paste(shift_start_date, "00:00:00"), format = "%Y-%m-%d %H:%M:%S", tz = tz_sast) + days(1)
    )
  )

bad_shift_rows <- shift_log %>% filter(is.na(shift_start_datetime) | is.na(shift_end_datetime))
if (nrow(bad_shift_rows) > 0) {
  print(bad_shift_rows)
  stop("[", PARTICIPANT_ID, "] one or more shift log rows failed to build a start/end datetime. Fix and re-run.")
}

explicit_shifts <- shift_log %>% filter(has_explicit_times)
fallback_shifts <- shift_log %>% filter(!has_explicit_times)

message(
  "[", PARTICIPANT_ID, "] Loaded ", nrow(shift_log), " shift row(s): ",
  nrow(explicit_shifts), " with explicit start/end times, ",
  nrow(fallback_shifts), " full-day default (Off/Postcall-style).",
  if (has_hospital_col) " hospital_site column found -- will be carried through." else ""
)


# ------------------------------------------------------------
# 3. Match each minute to a shift row.
#    Explicit-timed rows are checked first (priority). Full-day
#    default rows (Off/Postcall) only fill in minutes still
#    unmatched after that.
# ------------------------------------------------------------

match_one_set <- function(dt, shifts) {
  n <- length(dt)
  out_type <- rep(NA_character_, n)
  out_id   <- rep(NA_character_, n)
  out_hosp <- rep(NA_character_, n)
  if (nrow(shifts) == 0 || n == 0) {
    return(list(shift_type = out_type, shift_id = out_id, hospital_site = out_hosp))
  }

  hit <- outer(dt, shifts$shift_start_datetime, `>=`) &
         outer(dt, shifts$shift_end_datetime,   `<`)

  has_match <- rowSums(hit) > 0
  idx <- max.col(hit, ties.method = "first")
  idx[!has_match] <- NA

  out_type[has_match] <- shifts$shift_type[idx[has_match]]
  out_id[has_match]   <- shifts$shift_id[idx[has_match]]
  out_hosp[has_match] <- shifts$hospital_site[idx[has_match]]

  list(shift_type = out_type, shift_id = out_id, hospital_site = out_hosp)
}

primary <- match_one_set(clean$local_datetime, explicit_shifts)

remaining_idx <- which(is.na(primary$shift_type))
fallback <- match_one_set(clean$local_datetime[remaining_idx], fallback_shifts)

shift_type    <- primary$shift_type
shift_id      <- primary$shift_id
hospital_site <- primary$hospital_site
shift_type[remaining_idx]    <- fallback$shift_type
shift_id[remaining_idx]      <- fallback$shift_id
hospital_site[remaining_idx] <- fallback$hospital_site

if (nrow(explicit_shifts) > 0) {
  hit_explicit <- outer(clean$local_datetime, explicit_shifts$shift_start_datetime, `>=`) &
                  outer(clean$local_datetime, explicit_shifts$shift_end_datetime,   `<`)
  ambiguous_minutes <- sum(rowSums(hit_explicit) > 1)
  if (ambiguous_minutes > 0) {
    warning(
      "[", PARTICIPANT_ID, "] ", ambiguous_minutes,
      " minute(s) matched more than one explicit-timed shift row. ",
      "Check the shift log for overlapping start/end times."
    )
  }
}

clean_shift <- clean %>%
  mutate(
    shift_type    = shift_type,
    shift_id      = shift_id,
    hospital_site = hospital_site
  )

write_csv(clean_shift, output_file, na = "")
message("[", PARTICIPANT_ID, "] Created: ", output_file)


# ------------------------------------------------------------
# 4. Summary for verification
# ------------------------------------------------------------

clean_shift %>%
  summarise(
    total_minutes          = n(),
    minutes_without_shift  = sum(is.na(shift_type)),
    dates_without_shift    = n_distinct(date[is.na(shift_type)])
  ) %>%
  print()

clean_shift %>%
  distinct(date, shift_type) %>%
  arrange(date) %>%
  print(n = Inf)

clean_shift %>%
  filter(!is.na(shift_type)) %>%
  count(shift_type, sleep_nap_wake) %>%
  print(n = Inf)

message("[", PARTICIPANT_ID, "] Done. Next: master_04_graphs_and_summary.R")
