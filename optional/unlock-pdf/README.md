# Unlock PDF

A small window: drop PDFs (or whole folders) into it. Every file gets its own row with:

- its own **Password** cell (click and type; masked);
- a **PDF** button - an unlocked copy next to it, `name (unlocked).pdf`, password and restrictions removed;
- a **Pictures** button - one picture per page in a folder next to it, `name (pages)` with
  `name - page 001.png`, `... 002.png` and so on.

Below the list: **Password for all files** (used by every row whose own cell is empty - a row's own
password always wins), and **All -> unlocked PDF** / **All -> pictures**, which do every row that does
not have that yet. Pictures are PNG or JPG at 100, 150, 200 or 300 dpi (remembered).

Dropping only checks each file - "Needs the password", "No password needed" (restrictions only) or
"Not protected" (its PDF button is greyed out: nothing to unlock, Pictures still works). Work runs in
the background one file at a time, in the order you click. A wrong password leaves the row as
"Wrong password": fix its cell and press its button again. The originals are never changed and
nothing is ever overwritten (`(unlocked 2)`, `(pages 2)` ...). Double-click a row to show the result.

## Run it anywhere

`dist/unlock-pdf.jar` is self-contained (Apache PDFBox is inside). Any OS with **Java 8 or newer**:

```
java -jar unlock-pdf.jar                # opens the window
java -jar unlock-pdf.jar a.pdf folder/  # opens it with these already in the list
```

On Windows and most Linux desktops a double-click on the jar opens it too, if `.jar` is associated
with Java. Copy the one file; nothing else is needed.

Command line, for scripts (the password comes from an environment variable so it never shows up in
the process list):

```
UNLOCK_PDF_PASSWORD=secret java -jar unlock-pdf.jar --cli a.pdf b.pdf
UNLOCK_PDF_PASSWORD=secret java -jar unlock-pdf.jar --cli --pictures --format jpg --dpi 200 --no-copy a.pdf
```

Prints `DONE` (with `copy=` / `pictures=`), `NOT_PROTECTED`, `NEEDS_PASSWORD`, `WRONG_PASSWORD` or
`ERROR` per file; exit code 0 when every file ended done or was not protected.

Pages are rendered by PDFBox itself. PDFs that embed JPEG 2000 or JBIG2 images (some scanned
documents) need extra image plugins PDFBox does not ship, and those images can come out blank.

## On this PC

`..\unlock-pdf.bat` builds the jar if needed, puts an **Unlock PDF** shortcut (padlock) on the Desktop
and in Start, and opens the app. You can also drop PDFs straight onto that shortcut.

## Building

`build.ps1` (Windows) downloads PDFBox 3.0.8, fontbox, pdfbox-io and commons-logging 1.4.0 from Maven
Central, checks each against its published SHA-1, compiles `src/` for Java 8 and writes
`dist/unlock-pdf.jar`. Elsewhere, the same in two commands with those four jars in `lib/`:

```
javac --release 8 -cp "lib/*" -d classes $(find src -name '*.java')
# then put classes/ and the contents of lib/*.jar into one jar with Main-Class: pcsetup.unlockpdf.UnlockPdf
```
