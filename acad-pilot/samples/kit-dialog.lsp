;; Sample LISP commands for the ui driver's tests: KITDIALOG opens a DCL dialog, KITALERT shows an alert. Self-contained:
;; the dialog's DCL is written to a temp file, so only this file needs loading.
;; KITDIALOG prints one line "KITDIALOG <field>=<value> ..." with what the dialog returned, then shows an alert with the result.
;; "Check..." opens an alert on top of the dialog. Made-up data only.
(setq kit-dialog-dcl
  '("kitdialog : dialog {"
    "  label = \"Kit Sample Dialog\";"
    "  : edit_box { key = \"name\"; label = \"Name:\"; edit_width = 24; }"
    "  : edit_box { key = \"qty\"; label = \"Quantity:\"; edit_width = 8; }"
    "  : toggle { key = \"notes\"; label = \"Include notes\"; }"
    "  : radio_row { key = \"size\";"
    "    : radio_button { key = \"small\"; label = \"Small\"; value = \"1\"; }"
    "    : radio_button { key = \"large\"; label = \"Large\"; }"
    "  }"
    "  : popup_list { key = \"layer\"; label = \"Layer:\"; edit_width = 16; }"
    "  : list_box { key = \"parts\"; label = \"Parts:\"; multiple_select = true; height = 5; }"
    "  : button { key = \"check\"; label = \"Check...\"; }"
    "  ok_cancel;"
    "}"))

(defun kit-write-dcl (/ f h)
  (setq f (vl-filename-mktemp "kitdlg" nil ".dcl") h (open f "w"))
  (foreach l kit-dialog-dcl (write-line l h))
  (close h)
  f)

(defun kit-join (lst sep / s)
  (setq s "")
  (foreach x lst (setq s (if (= s "") x (strcat s sep x))))
  s)

(defun c:KITDIALOG (/ dcl id rc name qty qty-action notes size layer parts layers partlist)
  (setq layers '("Walls" "Doors" "Windows")
        partlist '("Bolt M8" "Nut M8" "Washer 8" "Bracket A" "Bracket B")
        qty-action "")
  (setq dcl (kit-write-dcl) id (load_dialog dcl))
  (if (not (new_dialog "kitdialog" id))
    (progn (alert "The sample dialog could not be loaded") (exit)))
  (start_list "layer") (mapcar 'add_list layers) (end_list)
  (start_list "parts") (mapcar 'add_list partlist) (end_list)
  (set_tile "layer" "0")
  ;; edit box actions run when the box loses the focus: qty-action shows whether that happened
  (action_tile "qty" "(setq qty-action $value)")
  (action_tile "check" "(alert (strcat \"Name is now: \" (get_tile \"name\")))")
  (action_tile "accept"
    "(setq name (get_tile \"name\") qty (get_tile \"qty\") notes (get_tile \"notes\") size (get_tile \"size\")
           layer (nth (atoi (get_tile \"layer\")) layers)
           parts (mapcar '(lambda (i) (nth i partlist)) (read (strcat \"(\" (get_tile \"parts\") \")\"))))
     (done_dialog 1)")
  (setq rc (start_dialog))
  (unload_dialog id)
  (vl-file-delete dcl)
  (if (= rc 1)
    (progn
      (princ (strcat "\nKITDIALOG name=" name " qty=" qty " qty-action=" qty-action " notes=" notes " size=" size
                     " layer=" layer " parts=" (kit-join parts ",")))
      (alert (strcat "Saved " name)))
    (princ "\nKITDIALOG cancelled"))
  (princ))

(defun c:KITALERT ()
  (alert "Hello from KITALERT")
  (princ "\nKITALERT done")
  (princ))
(princ "\nkit-dialog.lsp loaded: KITDIALOG, KITALERT")
(princ)
