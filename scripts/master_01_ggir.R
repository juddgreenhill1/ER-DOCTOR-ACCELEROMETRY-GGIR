# ============================================================
# MASTER SCRIPT 1 of 4: GGIR processing -> clean one-minute ENMO CSV
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
#   Rscript master_01_ggir.R <PARTICIPANT_ID>
.args <- commandArgs(trailingOnly = TRUE)
if (length(.args) >= 1 && nzchar(.args[1])) PARTICIPANT_ID <- .args[1]
#
# What this script deliberately does NOT do:
#   It does not classify minutes as sleep/nap/waking, and it does not
#   compute PA category or MVPA. The old per-participant GGIR scripts
#   mixed "run GGIR" with "classify sleep/PA" in one file, which meant
#   GGIR's own automatic sleep detection silently competed with the
#   manual sleep/nap log used later. This script's only job is: run
#   GGIR, export a clean one-minute CSV (timestamp, ENMO_mg, valid_minute
#   + GGIR's own QC columns). master_02 then applies the manual sleep/nap
#   log as the single source of truth for Sleep/Nap/Wake and PA category.
# ============================================================

required_packages <- c("GGIR", "data.table")
missing_packages <- required_packages[!required_packages %in% rownames(installed.packages())]
if (length(missing_packages) > 0) install.packages(missing_packages)

library(GGIR)
library(data.table)


# ------------------------------------------------------------
# 1. Paths (derived entirely from PARTICIPANT_ID -- do not edit below
#    this point unless the folder convention itself changes)
# ------------------------------------------------------------

# Root folder holding one sub-folder per participant (see README).
# Set the FINAL_ER_ROOT environment variable, or edit the fallback path.
final_er_root <- Sys.getenv("FINAL_ER_ROOT", unset = "path/to/FINAL_ER")
study_timezone <- "Africa/Johannesburg"

project_dir       <- file.path(final_er_root, PARTICIPANT_ID)
bin_dir           <- file.path(project_dir, "raw_bin")
sleep_log_file    <- file.path(project_dir, "sleep_log", paste0(PARTICIPANT_ID, "_GGIR_sleep_log.csv"))
ggir_output_dir   <- file.path(project_dir, "output", "GGIR")
clean_output_dir  <- file.path(project_dir, "output", "clean_csv")

dir.create(ggir_output_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(clean_output_dir, recursive = TRUE, showWarnings = FALSE)


# ------------------------------------------------------------
# 2. Check inputs exist before doing anything expensive
# ------------------------------------------------------------

if (!dir.exists(bin_dir)) {
  stop("[", PARTICIPANT_ID, "] raw_bin folder not found: ", bin_dir)
}

bin_files <- list.files(bin_dir, pattern = "\\.bin$", full.names = TRUE, ignore.case = TRUE)
if (length(bin_files) == 0) {
  stop("[", PARTICIPANT_ID, "] no .bin files found in: ", bin_dir)
}

if (!file.exists(sleep_log_file)) {
  stop(
    "[", PARTICIPANT_ID, "] sleep log not found: ", sleep_log_file,
    "\nExpected standard filename: ", PARTICIPANT_ID, "_GGIR_sleep_log.csv ",
    "inside the sleep_log/ folder. See the repository README."
  )
}

message("[", PARTICIPANT_ID, "] Found ", length(bin_files), " .bin file(s).")
message("[", PARTICIPANT_ID, "] Sleep log: ", sleep_log_file)


# ------------------------------------------------------------
# 3. Run GGIR
# ------------------------------------------------------------

GGIR(
  mode = 1:5,
  datadir = bin_dir,
  outputdir = ggir_output_dir,
  do.report = c(2, 4, 5),
  desiredtz = study_timezone,

  do.enmo = TRUE,
  acc.metric = "ENMO",
  windowsizes = c(5, 900, 3600),

  loglocation = sleep_log_file,
  colid = 1,   # column 1 = participant ID
  coln1 = 2,   # column 2 = onset of first night
  relyonguider = FALSE,
  sleepwindowType = "SPT",

  part5_agg2_60seconds = TRUE,
  save_ms5rawlevels = TRUE,
  save_ms5raw_format = "csv",
  save_ms5raw_without_invalid = FALSE,
  timewindow = c("MM", "WW"),

  do.parallel = TRUE,
  maxNcores = 2,
  overwrite = FALSE,
  print.filename = TRUE
)


# ------------------------------------------------------------
# 4. Find the Part 5 one-minute CSV(s) GGIR exported
# ------------------------------------------------------------

all_exported_csv <- list.files(
  ggir_output_dir, pattern = "\\.csv$", full.names = TRUE,
  recursive = TRUE, ignore.case = TRUE
)

minute_csv_files <- all_exported_csv[grepl("ms5\\.outraw", all_exported_csv, ignore.case = TRUE)]

# Exclude GGIR's auxiliary exports that also live under ms5.outraw but are
# NOT the one-minute time series (they have a different structure and will
# fail the timenum/ACC column check below):
#   behavioralcodes*.csv      - legend of class_id codes
#   sib.reports/sib_report*.csv - sustained inactivity bout report
minute_csv_files <- minute_csv_files[
  !grepl("behavio|legend", basename(minute_csv_files), ignore.case = TRUE) &
  !grepl("sib\\.reports|sib_report", minute_csv_files, ignore.case = TRUE)
]

if (length(minute_csv_files) == 0) {
  stop(
    "[", PARTICIPANT_ID, "] GGIR finished but no Part 5 time-series CSV was found. ",
    "Check: ", file.path(ggir_output_dir, "meta", "ms5.outraw")
  )
}

message("[", PARTICIPANT_ID, "] Found ", length(minute_csv_files), " Part 5 time-series CSV file(s).")


# ------------------------------------------------------------
# 5. Export a clean, minimal one-minute CSV
#    (timestamp, date, time, ENMO_mg, valid_minute + GGIR passthrough
#    columns -- no sleep/nap/PA classification here, see note at top)
# ------------------------------------------------------------

clean_ggir_minute_file <- function(input_file, timezone) {

  message("[", PARTICIPANT_ID, "] Cleaning: ", input_file)

  d <- fread(input_file, na.strings = c("", "NA", "NaN"))

  required_columns <- c("timenum", "ACC")
  missing_required <- setdiff(required_columns, names(d))
  if (length(missing_required) > 0) {
    stop(
      "[", PARTICIPANT_ID, "] missing expected column(s) in ", basename(input_file),
      ": ", paste(missing_required, collapse = ", ")
    )
  }

  d[, timestamp := as.POSIXct(timenum, origin = "1970-01-01", tz = timezone)]
  d[, date := as.Date(timestamp, tz = timezone)]
  d[, time := format(timestamp, format = "%H:%M:%S", tz = timezone)]

  setnames(d, old = "ACC", new = "ENMO_mg")

  # Flag ENMO values that look like they're in g rather than mg
  enmo_99th <- quantile(d$ENMO_mg, probs = 0.99, na.rm = TRUE)
  if (is.finite(enmo_99th) && enmo_99th < 2) {
    warning(
      "[", PARTICIPANT_ID, "] ENMO values in ", basename(input_file),
      " look unusually small -- check they are in mg, not g."
    )
  }

  if ("invalidepoch" %in% names(d)) {
    d[, valid_minute := (is.na(invalidepoch) | invalidepoch == 0)]
  } else {
    warning("[", PARTICIPANT_ID, "] no invalidepoch column found in ", basename(input_file))
    d[, valid_minute := !is.na(ENMO_mg)]
  }

  first_columns <- c("timestamp", "date", "time", "ENMO_mg", "valid_minute")
  setcolorder(d, c(first_columns, setdiff(names(d), first_columns)))

  input_name <- tools::file_path_sans_ext(basename(input_file))
  out_file <- file.path(clean_output_dir, paste0(input_name, "_1min_all.csv"))
  fwrite(d, out_file, na = "")
  message("[", PARTICIPANT_ID, "] Created: ", out_file)

  out_file
}

output_files <- vapply(minute_csv_files, clean_ggir_minute_file, character(1), timezone = study_timezone)

message("[", PARTICIPANT_ID, "] GGIR processing complete. Next: master_02_flag_sleep_naps.R")
