# ============================================================
# MASTER SCRIPT 5: Combine ALL participants into one master workbook
#                  + apply inclusion/exclusion criteria
#
# Reads every participant's:
#   output/{ID}_summary_report.xlsx                        (your report)
#   output/GGIR/.../results/part2_summary.csv              (QC: calibration, wear)
#   output/GGIR/.../results/QC/data_quality_report.csv     (QC: file integrity)
#   output/GGIR/.../results/QC/part4_nightsummary_sleep_full.csv
#   output/GGIR/.../results/part5_personsummary_MM_*.csv   (valid days)
#   output/GGIR/.../results/part5_personsummary_WW_*.csv
#
# Writes:
#   FINAL_ER/_MASTER/MASTER_all_participants.xlsx
#
# Nothing is deleted or removed. Participants failing the criteria are
# FLAGGED (meets_criteria / exclusion_reason) and listed on the
# Exclusions sheet -- you filter when analysing.
#
# Missing files never stop the run; they're logged on _Provenance.
#
# USAGE:
#   Rscript master_05_combine_all.R
#   Rscript master_05_combine_all.R S01 S02 S03     (only these)
# ============================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(readxl)
  library(openxlsx)
})

# ------------------------------------------------------------
# 0. Settings
# ------------------------------------------------------------

# Set FINAL_ER_ROOT in your environment to override, e.g.
#   Mac/Linux: export FINAL_ER_ROOT=/path/to/FINAL_ER
#   Windows:   $env:FINAL_ER_ROOT="C:/path/to/FINAL_ER"
final_er_root <- Sys.getenv(
  "FINAL_ER_ROOT",
  unset = "path/to/FINAL_ER"
)

# >>> INCLUSION / EXCLUSION CRITERIA -- edit these two numbers to change <<<
CRIT_MIN_VALID_DAYS <- 14      # Nvaliddays (GGIR part 5) must be >= this
CRIT_MAX_CALIB_ERR  <- 0.01    # post-calibration error (g) must be < this
# Plus: file must not be corrupt, must not be too short, and GGIR's
# QCmessage must report "no problems detected".

# ------------------------------------------------------------
# WHAT GOES IN THE WORKBOOK
# All three are OFF per supervisor feedback (Aug 2026):
#   "We really don't need the sleep data (you don't need to populate the
#    Sleep_Nights_All sheet). Don't worry about adding SD to the
#    variables, all of that will be calculated during analysis. We also
#    don't need to separate day vs night or postcall vs off at this
#    stage. Again the analysis will group the data."
# Flip any of them back to TRUE and re-run -- nothing is lost, the
# source files are all still read.
# ------------------------------------------------------------

INCLUDE_SLEEP_NIGHTS      <- FALSE  # Sleep_Nights_All sheet (GGIR part 4)
SPLIT_MEAN_SD             <- FALSE  # add numeric _mean / _sd columns
INCLUDE_COMPARISON_SHEETS <- FALSE  # Day_vs_Night_All, Postcall_vs_Off_All

# Folders like "S01 - non compliant" / "S02 - WITHDRAWN" are excluded by
# default. Set TRUE to pull them in -- they're then auto-flagged via
# their folder_flag as an exclusion reason.
INCLUDE_FLAGGED <- FALSE

out_dir  <- file.path(final_er_root, "_MASTER")
out_file <- file.path(out_dir, "MASTER_all_participants.xlsx")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!dir.exists(final_er_root)) {
  stop("FINAL_ER root not found: ", final_er_root,
       "\nSet FINAL_ER_ROOT or edit the default at the top of this script.")
}

message("Root: ", final_er_root)
message("Criteria: Nvaliddays >= ", CRIT_MIN_VALID_DAYS,
        ", calib_err < ", CRIT_MAX_CALIB_ERR,
        ", file intact, recalibration OK")

# ------------------------------------------------------------
# 1. Find participant folders
# ------------------------------------------------------------

all_folders <- list.dirs(final_er_root, recursive = FALSE, full.names = FALSE)
all_folders <- all_folders[grepl("^S[0-9]+", all_folders)]

folder_tbl <- tibble(folder = all_folders) %>%
  mutate(
    participant_id = str_extract(folder, "^S[0-9]+"),
    folder_flag    = if_else(folder == participant_id, NA_character_,
                             str_trim(str_remove(folder, "^S[0-9]+\\s*-?\\s*")))
  ) %>%
  arrange(as.numeric(str_remove(participant_id, "^S")))

.args <- commandArgs(trailingOnly = TRUE)
if (length(.args) > 0) folder_tbl <- folder_tbl %>% filter(participant_id %in% .args)

if (!INCLUDE_FLAGGED) {
  dropped    <- folder_tbl %>% filter(!is.na(folder_flag))
  folder_tbl <- folder_tbl %>% filter(is.na(folder_flag))
  if (nrow(dropped) > 0)
    message("Excluding flagged folders (set INCLUDE_FLAGGED <- TRUE to keep): ",
            paste(dropped$folder, collapse = ", "))
}

if (nrow(folder_tbl) == 0) stop("No participant folders found.")
message("Participants to combine: ", nrow(folder_tbl))

# ------------------------------------------------------------
# 2. Helpers
# ------------------------------------------------------------

provenance <- tibble()
note <- function(id, item, status, detail = "") {
  provenance <<- bind_rows(provenance, tibble(
    participant_id = id, item = item, status = status, detail = detail))
}

safe_sheet <- function(path, sheet, id) {
  if (!file.exists(path)) { note(id, sheet, "MISSING", "no summary_report.xlsx"); return(NULL) }
  ok <- tryCatch(sheet %in% excel_sheets(path), error = function(e) FALSE)
  if (!ok) { note(id, sheet, "MISSING", "sheet not in workbook"); return(NULL) }
  df <- tryCatch(read_excel(path, sheet = sheet), error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) { note(id, sheet, "EMPTY"); return(NULL) }
  note(id, sheet, "OK", paste(nrow(df), "rows"))
  df %>% mutate(participant_id = id, .before = 1)
}

safe_csv <- function(path, id, label) {
  if (length(path) == 0 || is.na(path[1]) || !file.exists(path[1])) {
    note(id, label, "MISSING"); return(NULL)
  }
  df <- tryCatch(suppressWarnings(read_csv(path[1], show_col_types = FALSE)),
                 error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) { note(id, label, "EMPTY"); return(NULL) }
  note(id, label, "OK", paste(nrow(df), "rows"))
  df %>% mutate(participant_id = id, .before = 1)
}

# "317.7 (108.5)"  ->  numeric _mean and _sd columns
expand_mean_sd <- function(df) {
  for (col in names(df)[str_detect(names(df), "mean \\(SD\\)")]) {
    m    <- str_match(as.character(df[[col]]), "([-0-9.]+)\\s*\\(([-0-9.]+)\\)")
    base <- str_trim(str_remove(col, ":?\\s*mean \\(SD\\)"))
    df[[paste0(base, "_mean")]] <- suppressWarnings(as.numeric(m[, 2]))
    df[[paste0(base, "_sd")]]   <- suppressWarnings(as.numeric(m[, 3]))
  }
  df
}

# pull a single value out of a one-row data frame, tolerating a missing column
pick <- function(df, candidates, numeric = TRUE) {
  if (is.null(df)) return(NA)
  col <- intersect(candidates, names(df))
  if (length(col) == 0) return(NA)
  v <- df[[col[1]]][1]
  if (numeric) suppressWarnings(as.numeric(v)) else as.character(v)
}

# ------------------------------------------------------------
# 3. Read everything
# ------------------------------------------------------------

stack <- list(basic = list(), pa_shift = list(), pa_meansd = list(),
              pa_raw = list(), daynight = list(), postcall = list(),
              daily = list(), nights = list(),
              person_mm = list(), person_ww = list())
qc_rows <- list()

for (i in seq_len(nrow(folder_tbl))) {
  id     <- folder_tbl$participant_id[i]
  folder <- folder_tbl$folder[i]
  message("  [", i, "/", nrow(folder_tbl), "] ", id)

  p_out <- file.path(final_er_root, folder, "output")
  xlsx  <- file.path(p_out, paste0(id, "_summary_report.xlsx"))
  ggir  <- file.path(p_out, "GGIR", "output_raw_bin", "results")

  stack$basic[[id]]     <- safe_sheet(xlsx, "Basic_Stats", id)
  stack$pa_shift[[id]]  <- safe_sheet(xlsx, "PA_by_ShiftType", id)
  stack$pa_meansd[[id]] <- safe_sheet(xlsx, "PA_Minutes_MeanSD_by_ShiftType", id)
  stack$pa_raw[[id]]    <- safe_sheet(xlsx, "PA_Minutes_per_Shift_raw", id)
  stack$daynight[[id]]  <- safe_sheet(xlsx, "Day_vs_Night", id)
  stack$postcall[[id]]  <- safe_sheet(xlsx, "Postcall_vs_Off", id)
  stack$daily[[id]]     <- safe_sheet(xlsx, "Daily_Summary", id)

  nights_i <- safe_csv(file.path(ggir, "QC", "part4_nightsummary_sleep_full.csv"),
                       id, "part4_nights")
  mm_i <- safe_csv(list.files(ggir, "^part5_personsummary_MM.*\\.csv$", full.names = TRUE),
                   id, "part5_person_MM")
  ww_i <- safe_csv(list.files(ggir, "^part5_personsummary_WW.*\\.csv$", full.names = TRUE),
                   id, "part5_person_WW")
  stack$nights[[id]]    <- nights_i
  stack$person_mm[[id]] <- mm_i
  stack$person_ww[[id]] <- ww_i

  p2  <- safe_csv(file.path(ggir, "part2_summary.csv"), id, "part2_summary")
  dqr <- safe_csv(file.path(ggir, "QC", "data_quality_report.csv"), id, "data_quality_report")

  qc_rows[[id]] <- tibble(
    participant_id = id,
    folder_flag    = folder_tbl$folder_flag[i],
    processed      = !is.null(mm_i) || !is.null(p2),
    Nvaliddays     = pick(mm_i, "Nvaliddays"),
    Nvaliddays_WD  = pick(mm_i, "Nvaliddays_WD"),
    Nvaliddays_WE  = pick(mm_i, "Nvaliddays_WE"),
    n_sleep_nights = if (is.null(nights_i)) NA_integer_ else nrow(nights_i),
    calib_err      = {
      v <- pick(p2, "calib_err"); if (is.na(v)) pick(dqr, "cal.error.end") else v },
    calib_status   = pick(p2, "calib_status", numeric = FALSE),
    QCmessage      = pick(dqr, "QCmessage", numeric = FALSE),
    file_corrupt   = pick(dqr, "file.corrupt", numeric = FALSE),
    file_too_short = pick(dqr, "file.too.short", numeric = FALSE),
    clipping_score = pick(p2, "clipping_score"),
    meas_dur_dys   = pick(p2, "meas_dur_dys"),
    wear_dur_dys   = pick(p2, c("wear_dur_def_proto_day", "wear_dur_dys"))
  )
}

# Stack a list of data frames. GGIR types some columns differently between
# participants -- e.g. ID reads as text ("S01") for most but as a number for
# any whose .bin filename is numeric, which makes bind_rows() refuse to
# combine them. Any column whose type is not consistent across participants
# is coerced to text first, and reported so nothing changes silently.
bind <- function(x) {
  x <- compact(x)
  if (length(x) == 0) return(NULL)

  types <- list()
  for (d in x) {
    for (nm in names(d)) types[[nm]] <- unique(c(types[[nm]], class(d[[nm]])[1]))
  }
  mixed <- names(types)[vapply(types, length, integer(1)) > 1]

  if (length(mixed) > 0) {
    message("  (mixed column type across participants -- coercing to text: ",
            paste(mixed, collapse = ", "), ")")
    x <- lapply(x, function(d) {
      for (nm in intersect(mixed, names(d))) d[[nm]] <- as.character(d[[nm]])
      d
    })
  }
  bind_rows(x)
}

daily     <- bind(stack$daily)
pa_shift  <- bind(stack$pa_shift)
pa_meansd <- bind(stack$pa_meansd)
pa_raw    <- bind(stack$pa_raw)
daynight  <- bind(stack$daynight)
postcall  <- bind(stack$postcall)
nights    <- bind(stack$nights)
person_mm <- bind(stack$person_mm)
person_ww <- bind(stack$person_ww)

# ------------------------------------------------------------
# Drop GGIR's own "ID" column.
#
# With idloc = 1, GGIR takes ID from the subject field written into the
# GENEActiv device header at setup -- NOT from the filename. Those values
# are device-setup numbers and do not match the participant IDs
# (e.g. a numeric setup code, or a generic label like "Subject1"). Left in place the column
# looks like a participant identifier and isn't one, so it is removed.
# Every sheet is keyed on `participant_id`, taken from the folder name.
# ------------------------------------------------------------

drop_ggir_id <- function(d, label) {
  if (is.null(d) || !"ID" %in% names(d)) return(d)
  message("  (dropped GGIR's device-derived 'ID' column from ", label,
          " -- use participant_id instead)")
  d %>% select(-ID)
}

nights    <- drop_ggir_id(nights,    "Sleep_Nights_All")
person_mm <- drop_ggir_id(person_mm, "GGIR_PersonSummary_MM")
person_ww <- drop_ggir_id(person_ww, "GGIR_PersonSummary_WW")

if (SPLIT_MEAN_SD && !is.null(pa_meansd)) pa_meansd <- expand_mean_sd(pa_meansd)

# ------------------------------------------------------------
# 4. Apply the inclusion / exclusion criteria
# ------------------------------------------------------------

is_true <- function(x) !is.na(x) & tolower(as.character(x)) %in% c("true", "1", "yes")

qc <- bind_rows(qc_rows) %>%
  mutate(
    wear_pct = if_else(!is.na(meas_dur_dys) & meas_dur_dys > 0,
                       round(100 * wear_dur_dys / meas_dur_dys, 1), NA_real_),

    fail_not_processed = !processed,
    fail_valid_days    = !is.na(Nvaliddays) & Nvaliddays < CRIT_MIN_VALID_DAYS,
    fail_valid_days_na = processed & is.na(Nvaliddays),
    fail_calib         = !is.na(calib_err) & calib_err >= CRIT_MAX_CALIB_ERR,
    fail_corrupt       = is_true(file_corrupt),
    fail_too_short     = is_true(file_too_short),
    fail_qc_message    = !is.na(QCmessage) & !str_detect(QCmessage, regex("no problems detected", ignore_case = TRUE)),
    fail_folder_flag   = !is.na(folder_flag),

    exclusion_reason = pmap_chr(
      list(fail_not_processed, fail_valid_days, fail_valid_days_na, fail_calib,
           fail_corrupt, fail_too_short, fail_qc_message, fail_folder_flag,
           Nvaliddays, calib_err, QCmessage, folder_flag),
      function(np, vd, vdna, cal, cor, sh, qcm, ff, nv, ce, qm, fl) {
        r <- c()
        if (np)   r <- c(r, "not processed (no GGIR output)")
        if (vd)   r <- c(r, sprintf("only %s valid days (need >= %s)", nv, CRIT_MIN_VALID_DAYS))
        if (vdna) r <- c(r, "Nvaliddays could not be read")
        if (cal)  r <- c(r, sprintf("calibration error %.4f g (need < %s)", ce, CRIT_MAX_CALIB_ERR))
        if (cor)  r <- c(r, "file flagged corrupt")
        if (sh)   r <- c(r, "file flagged too short")
        if (qcm)  r <- c(r, paste0("QC message: ", qm))
        if (ff)   r <- c(r, paste0("folder marked: ", fl))
        if (length(r) == 0) NA_character_ else paste(r, collapse = "; ")
      }),

    meets_criteria = if_else(processed, is.na(exclusion_reason), NA)
  )

exclusions <- qc %>%
  select(participant_id, meets_criteria, exclusion_reason, processed,
         Nvaliddays, Nvaliddays_WD, Nvaliddays_WE, n_sleep_nights,
         calib_err, calib_status, QCmessage, file_corrupt, file_too_short,
         clipping_score, meas_dur_dys, wear_dur_dys, wear_pct, folder_flag) %>%
  arrange(desc(is.na(meets_criteria)), meets_criteria, participant_id)

# ------------------------------------------------------------
# 5. Participant_Overview -- one row per participant
# ------------------------------------------------------------

overview <- bind(stack$basic)

if (!is.null(overview)) {
  overview <- overview %>%
    mutate(Metric = str_trim(Metric)) %>%
    distinct(participant_id, Metric, .keep_all = TRUE) %>%
    pivot_wider(names_from = Metric, values_from = Value) %>%
    mutate(across(-participant_id, ~ {
      n <- suppressWarnings(as.numeric(.x))
      if (all(is.na(n) | is.na(.x) | .x == "")) .x else n
    }))
} else {
  overview <- folder_tbl %>% select(participant_id)
}

if (!is.null(daily)) {
  overview <- overview %>% left_join(
    daily %>% group_by(participant_id) %>%
      summarise(n_days_in_daily      = n(),
                mean_daily_MVPA_min  = round(mean(MVPA_minutes,  na.rm = TRUE), 1),
                mean_daily_sleep_min = round(mean(sleep_minutes, na.rm = TRUE), 1),
                .groups = "drop"), by = "participant_id")
}
if (INCLUDE_SLEEP_NIGHTS && !is.null(nights)) {
  sc <- intersect(c("SleepDurationInSpt", "SptDuration"), names(nights))[1]
  overview <- overview %>% left_join(
    nights %>% group_by(participant_id) %>%
      summarise(mean_sleep_dur_h = if (!is.na(sc))
                  round(mean(.data[[sc]], na.rm = TRUE), 2) else NA_real_,
                .groups = "drop"), by = "participant_id")
}
if (!is.null(pa_raw)) {
  overview <- overview %>% left_join(
    pa_raw %>% group_by(participant_id) %>%
      summarise(n_shifts    = n_distinct(shift_id),
                shift_types = paste(sort(unique(shift_type)), collapse = ", "),
                .groups = "drop"), by = "participant_id")
}

# Criteria columns go FIRST so they're the first thing you see
overview <- folder_tbl %>%
  select(participant_id, folder) %>%
  left_join(qc %>% select(participant_id, meets_criteria, exclusion_reason,
                          Nvaliddays, calib_err, wear_pct),
            by = "participant_id") %>%
  left_join(overview, by = "participant_id") %>%
  relocate(participant_id, meets_criteria, exclusion_reason)

# ------------------------------------------------------------
# 6. Write the workbook
# ------------------------------------------------------------

wb  <- createWorkbook()
hdr <- createStyle(textDecoration = "bold", fgFill = "#DDEBF7",
                   border = "bottom", halign = "left")
bad <- createStyle(fgFill = "#FFC7CE", fontColour = "#9C0006")
good<- createStyle(fgFill = "#C6EFCE", fontColour = "#006100")

add <- function(name, df) {
  if (is.null(df) || nrow(df) == 0) { message("  (skipped empty sheet: ", name, ")"); return(invisible()) }
  addWorksheet(wb, name)
  writeData(wb, name, df, headerStyle = hdr)
  freezePane(wb, name, firstActiveRow = 2, firstActiveCol = 2)
  addFilter(wb, name, rows = 1, cols = seq_len(ncol(df)))
  setColWidths(wb, name, cols = seq_len(ncol(df)), widths = "auto")
  if ("meets_criteria" %in% names(df)) {
    col <- which(names(df) == "meets_criteria")
    conditionalFormatting(wb, name, cols = col, rows = 2:(nrow(df) + 1),
                          rule = "==FALSE", style = bad)
    conditionalFormatting(wb, name, cols = col, rows = 2:(nrow(df) + 1),
                          rule = "==TRUE",  style = good)
  }
  message("  + ", name, ": ", nrow(df), " rows x ", ncol(df), " cols")
}

n_pass <- sum(qc$meets_criteria %in% TRUE)
n_fail <- sum(qc$meets_criteria %in% FALSE)
n_unk  <- sum(is.na(qc$meets_criteria))

readme <- tibble(
  Item = c("Master workbook", "Generated", "Root", "Participants",
           "", "CRITERIA APPLIED", "  Minimum valid days", "  Max calibration error",
           "  File integrity", "  Recalibration",
           "", "RESULT", "  Meet criteria", "  Fail criteria", "  Not yet processed",
           "", "Participant_Overview", "PA_per_Shift_All", "Daily_Summary_All",
           "PA_by_ShiftType_All", "PA_MeanSD_by_ShiftType_All",
           "GGIR_PersonSummary_MM", "GGIR_PersonSummary_WW",
           "Exclusions", "_Provenance",
           "", "OMITTED", "", "NOTE 1", "NOTE 2"),
  Detail = c(
    "All participants combined from per-participant summary reports",
    format(Sys.time(), "%Y-%m-%d %H:%M"), final_er_root,
    paste(nrow(folder_tbl), "folders:", paste(folder_tbl$participant_id, collapse = ", ")),
    "",
    "Participants failing any check are FLAGGED, not removed",
    paste0("Nvaliddays >= ", CRIT_MIN_VALID_DAYS, "  (GGIR part 5)"),
    paste0("calib_err < ", CRIT_MAX_CALIB_ERR, " g  (GGIR part 2, post-calibration)"),
    "file.corrupt = FALSE and file.too.short = FALSE",
    "QCmessage must report 'no problems detected'",
    "", "",
    paste(n_pass, "participants"), paste(n_fail, "participants"),
    paste(n_unk, "participants"),
    "",
    "One row per participant. meets_criteria / exclusion_reason are the first columns.",
    "*** KEY SHEET *** One row per individual shift.",
    "One row per participant-day.",
    "One row per participant-shift-type.",
    "Mean (SD) as text, per participant-shift-type.",
    "GGIR part 5 person summary, MM window.",
    "GGIR part 5 person summary, WW window.",
    "Every QC value behind the include/exclude decision, one row per participant.",
    "What was found and what was missing, per participant.",
    "",
    paste0("Per supervisor (Aug 2026): ",
           if (!INCLUDE_SLEEP_NIGHTS) "Sleep_Nights_All, " else "",
           if (!INCLUDE_COMPARISON_SHEETS) "Day_vs_Night_All, Postcall_vs_Off_All, " else "",
           if (!SPLIT_MEAN_SD) "and the split _mean/_sd columns " else "",
           "omitted. Set the flags at the top of master_05 to TRUE and re-run to restore."),
    "",
    "ALL data is included regardless of criteria. Filter on meets_criteria = TRUE when analysing.",
    paste0("Minute-by-minute data is NOT here - ~2.9M rows exceeds Excel's 1,048,576 row limit. ",
           "Note: GGIR's own 'ID' column has been REMOVED from the GGIR sheets. It came from the ",
           "GENEActiv device header (idloc=1), not the filename, so it holds device-setup values ",
           "that do NOT match participant IDs. Always key on participant_id.")
  ))

add("ReadMe", readme)
add("Participant_Overview",       overview)

# PA_per_Shift_All first -- supervisor: "probably going to be the most
# important sheet".
add("PA_per_Shift_All",           pa_raw)
add("Daily_Summary_All",          daily)
add("PA_by_ShiftType_All",        pa_shift)
add("PA_MeanSD_by_ShiftType_All", pa_meansd)

if (INCLUDE_SLEEP_NIGHTS)      add("Sleep_Nights_All",    nights)
if (INCLUDE_COMPARISON_SHEETS) add("Day_vs_Night_All",    daynight)
if (INCLUDE_COMPARISON_SHEETS) add("Postcall_vs_Off_All", postcall)

add("GGIR_PersonSummary_MM",      person_mm)
add("GGIR_PersonSummary_WW",      person_ww)
add("Exclusions",                 exclusions)
add("_Provenance",                provenance)

saveWorkbook(wb, out_file, overwrite = TRUE)

# ------------------------------------------------------------
# 7. Report
# ------------------------------------------------------------

message("\n============================================================")
message("MASTER WORKBOOK: ", out_file)
message("Participants combined: ", nrow(folder_tbl))
message("\nCRITERIA  (Nvaliddays >= ", CRIT_MIN_VALID_DAYS,
        ", calib_err < ", CRIT_MAX_CALIB_ERR, ", file intact, recalibration OK)")
message("  Meet criteria    : ", n_pass)
message("  FAIL criteria    : ", n_fail)
message("  Not yet processed: ", n_unk)

failed <- qc %>% filter(meets_criteria %in% FALSE)
if (nrow(failed) > 0) {
  message("\nFlagged for exclusion:")
  for (i in seq_len(nrow(failed)))
    message("  ", failed$participant_id[i], " -- ", failed$exclusion_reason[i])
}

miss <- provenance %>% filter(status != "OK")
if (nrow(miss) > 0) {
  message("\nMissing / empty inputs (see _Provenance sheet): ",
          nrow(miss), " entries across ",
          length(unique(miss$participant_id)), " participants")
}
message("============================================================")
