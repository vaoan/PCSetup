package pcsetup.unlockpdf;

import java.awt.BasicStroke;
import java.awt.BorderLayout;
import java.awt.Color;
import java.awt.Component;
import java.awt.Desktop;
import java.awt.Dimension;
import java.awt.FlowLayout;
import java.awt.Font;
import java.awt.Graphics;
import java.awt.Graphics2D;
import java.awt.Image;
import java.awt.RenderingHints;
import java.awt.datatransfer.DataFlavor;
import java.awt.datatransfer.Transferable;
import java.awt.event.MouseAdapter;
import java.awt.event.MouseEvent;
import java.awt.geom.RoundRectangle2D;
import java.awt.image.BufferedImage;
import java.io.File;
import java.io.IOException;
import java.net.URI;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.prefs.Preferences;

import javax.imageio.IIOImage;
import javax.imageio.ImageIO;
import javax.imageio.ImageWriteParam;
import javax.imageio.ImageWriter;
import javax.imageio.stream.ImageOutputStream;
import javax.swing.BorderFactory;
import javax.swing.DefaultCellEditor;
import javax.swing.JButton;
import javax.swing.JCheckBox;
import javax.swing.JComboBox;
import javax.swing.JComponent;
import javax.swing.JFileChooser;
import javax.swing.JFrame;
import javax.swing.JLabel;
import javax.swing.JPanel;
import javax.swing.JPasswordField;
import javax.swing.JScrollPane;
import javax.swing.JTable;
import javax.swing.SwingConstants;
import javax.swing.SwingUtilities;
import javax.swing.TransferHandler;
import javax.swing.UIManager;
import javax.swing.filechooser.FileNameExtensionFilter;
import javax.swing.table.AbstractTableModel;
import javax.swing.table.DefaultTableCellRenderer;
import javax.swing.table.TableCellRenderer;

import org.apache.pdfbox.Loader;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.encryption.InvalidPasswordException;
import org.apache.pdfbox.rendering.ImageType;
import org.apache.pdfbox.rendering.PDFRenderer;

/**
 * Unlock PDF - drop PDFs into the window; each row has its own password and its own buttons:
 *   - PDF:      an unlocked copy next to the original, "name (unlocked).pdf";
 *   - Pictures: one picture per page in a folder next to it, "name (pages)/name - page 001.png".
 * A shared password below the list is used for rows that have none, and two buttons do all rows
 * at once. Originals are never changed. PDFs that open without a password but carry restrictions
 * (no print/copy/edit) need no password.
 *
 * Runs anywhere with Java 8+ (Windows, macOS, Linux): java -jar unlock-pdf.jar [files...]
 *
 * Command-line mode for scripts and tests (password from an environment variable, so it never
 * appears on a command line):
 *   UNLOCK_PDF_PASSWORD=... java -jar unlock-pdf.jar --cli [--pictures] [--format png|jpg]
 *                                                      [--dpi 150] [--no-copy] a.pdf folder/
 * Exit code 0 when every file ended Done or Not protected, 1 otherwise.
 */
public final class UnlockPdf {

    // ------------------------------------------------------------------------------------------
    // Core: no UI here, so the window and --cli share exactly the same logic.
    // ------------------------------------------------------------------------------------------

    enum Status {
        CHECKING("Checking..."), WORKING("Working..."), DONE("Done"),
        NO_PASSWORD_NEEDED("No password needed"), NOT_PROTECTED("Not protected"),
        NEEDS_PASSWORD("Needs the password"), WRONG_PASSWORD("Wrong password"), ERROR("Error");

        final String label;
        Status(String label) { this.label = label; }
    }

    /** What to make from a PDF. */
    static final class Options {
        boolean copy = true;
        boolean pictures = false;
        String format = "png";   // png or jpg
        int dpi = 150;
    }

    static final class Result {
        Status status;
        String detail = "";
        File copy;          // the unlocked PDF, when one was written
        File picturesDir;   // the folder of page pictures, when written
        int pictures;
        boolean encrypted;  // the source had a password or restrictions
    }

    interface Progress { void update(String what); }

    /** Only looks: does this PDF need a password, only restrictions, or nothing at all? */
    static Status probe(File source) {
        PDDocument doc = null;
        try {
            doc = Loader.loadPDF(source, "");
            return doc.isEncrypted() ? Status.NO_PASSWORD_NEEDED : Status.NOT_PROTECTED;
        } catch (InvalidPasswordException e) {
            return Status.NEEDS_PASSWORD;
        } catch (IOException e) {
            return Status.ERROR;
        } finally {
            if (doc != null) { try { doc.close(); } catch (IOException ignored) { } }
        }
    }

    /** Opens the PDF (empty password first, for restriction-only files) and makes what was asked. */
    static Result process(File source, String password, Options opt, Progress progress) {
        Result r = new Result();
        PDDocument doc = null;
        try {
            try {
                doc = Loader.loadPDF(source, "");
            } catch (InvalidPasswordException needsOne) {
                if (password == null || password.isEmpty()) {
                    r.status = Status.NEEDS_PASSWORD;
                    r.detail = "type its password (or the one for all files)";
                    return r;
                }
                try {
                    doc = Loader.loadPDF(source, password);
                } catch (InvalidPasswordException wrong) {
                    r.status = Status.WRONG_PASSWORD;
                    r.detail = "try another password";
                    return r;
                }
            }
            r.encrypted = doc.isEncrypted();

            // Pictures first: saving the unlocked copy changes the document's security state.
            if (opt.pictures) {
                r.picturesDir = renderPages(doc, source, opt, progress);
                r.pictures = doc.getNumberOfPages();
            }
            if (opt.copy && r.encrypted) {
                if (progress != null) progress.update("saving the unlocked copy...");
                r.copy = saveUnlocked(doc, source);
                doc = null; // saveUnlocked closed it
            }

            if (r.copy == null && r.picturesDir == null) {
                r.status = Status.NOT_PROTECTED;
                r.detail = "no password or restrictions - nothing to unlock";
            } else {
                r.status = Status.DONE;
                StringBuilder sb = new StringBuilder();
                if (r.copy != null) sb.append(r.copy.getName());
                if (r.picturesDir != null) {
                    if (sb.length() > 0) sb.append("  +  ");
                    sb.append(r.pictures).append(r.pictures == 1 ? " picture in " : " pictures in ").append(r.picturesDir.getName());
                }
                r.detail = sb.toString();
            }
            return r;
        } catch (IOException e) {
            r.status = Status.ERROR;
            r.detail = e.getMessage() == null ? e.toString() : e.getMessage();
            return r;
        } catch (RuntimeException e) {
            r.status = Status.ERROR;
            r.detail = e.toString();
            return r;
        } finally {
            if (doc != null) { try { doc.close(); } catch (IOException ignored) { } }
        }
    }

    /** Saves to a temp name, re-opens it to prove it has no encryption, then renames it. Closes doc. */
    static File saveUnlocked(PDDocument doc, File source) throws IOException {
        File out = unique(source, " (unlocked)", ".pdf");
        File tmp = new File(out.getParentFile(), out.getName() + ".unlocking");
        try {
            doc.setAllSecurityToBeRemoved(true);
            doc.save(tmp);
        } finally {
            doc.close();
        }
        PDDocument check = Loader.loadPDF(tmp);
        boolean clean = !check.isEncrypted();
        check.close();
        if (!clean) { tmp.delete(); throw new IOException("the copy was still encrypted"); }
        if (!tmp.renameTo(out)) { tmp.delete(); throw new IOException("could not write " + out.getName()); }
        return out;
    }

    /** One picture per page into a new "name (pages)" folder, numbered so they sort in order. */
    static File renderPages(PDDocument doc, File source, Options opt, Progress progress) throws IOException {
        File dir = unique(source, " (pages)", "");
        if (!dir.mkdirs()) throw new IOException("could not create " + dir.getName());
        String base = baseName(source);
        int pages = doc.getNumberOfPages();
        int digits = Math.max(3, String.valueOf(pages).length());
        String ext = "jpg".equals(opt.format) ? "jpg" : "png";
        PDFRenderer renderer = new PDFRenderer(doc);
        for (int i = 0; i < pages; i++) {
            if (progress != null) progress.update("page " + (i + 1) + " of " + pages + "...");
            BufferedImage img = renderer.renderImageWithDPI(i, opt.dpi, ImageType.RGB);
            File f = new File(dir, base + " - page " + String.format("%0" + digits + "d", i + 1) + "." + ext);
            if ("jpg".equals(ext)) writeJpeg(img, f, 0.92f); else ImageIO.write(img, "png", f);
            if (!f.isFile() || f.length() == 0) throw new IOException("could not write " + f.getName());
        }
        return dir;
    }

    static void writeJpeg(BufferedImage img, File f, float quality) throws IOException {
        Iterator<ImageWriter> writers = ImageIO.getImageWritersByFormatName("jpg");
        if (!writers.hasNext()) throw new IOException("no JPEG writer available");
        ImageWriter w = writers.next();
        ImageWriteParam p = w.getDefaultWriteParam();
        p.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);
        p.setCompressionQuality(quality);
        ImageOutputStream out = ImageIO.createImageOutputStream(f);
        try {
            w.setOutput(out);
            w.write(null, new IIOImage(img, null, null), p);
        } finally {
            out.close();
            w.dispose();
        }
    }

    static String baseName(File f) {
        String name = f.getName();
        int dot = name.lastIndexOf('.');
        return dot > 0 ? name.substring(0, dot) : name;
    }

    /** "name (unlocked).pdf" / "name (pages)", then "... 2)", "... 3)" - never overwrites anything. */
    static File unique(File source, String tag, String ext) {
        File dir = source.getAbsoluteFile().getParentFile();
        String base = baseName(source);
        String open = tag.substring(0, tag.length() - 1); // " (unlocked" without ")"
        File out = new File(dir, base + tag + ext);
        for (int n = 2; out.exists(); n++) out = new File(dir, base + open + " " + n + ")" + ext);
        return out;
    }

    /** Files as given; folders expanded to the PDFs inside them (recursively). */
    static List<File> collectPdfs(List<File> dropped) {
        Set<File> found = new LinkedHashSet<File>();
        for (File f : dropped) collect(f.getAbsoluteFile(), found, 0);
        return new ArrayList<File>(found);
    }

    private static void collect(File f, Set<File> found, int depth) {
        if (f.isDirectory()) {
            if (depth > 20) return;
            // A folder this app wrote holds pictures, not PDFs to process.
            if (depth > 0 && f.getName().matches(".* \\(pages( \\d+)?\\)")) return;
            File[] kids = f.listFiles();
            if (kids == null) return;
            java.util.Arrays.sort(kids);
            for (File k : kids) {
                // A folder that was already processed holds our own outputs; skip them there.
                if (k.isFile() && k.getName().contains(" (unlocked")) continue;
                collect(k, found, depth + 1);
            }
        } else if (f.isFile() && f.getName().toLowerCase(Locale.ROOT).endsWith(".pdf")) {
            found.add(f);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Entry point
    // ------------------------------------------------------------------------------------------

    public static void main(String[] args) {
        // PDFBox logs font and parsing chatter through commons-logging; none of it is useful here.
        System.setProperty("org.apache.commons.logging.Log", "org.apache.commons.logging.impl.NoOpLog");

        final List<File> files = new ArrayList<File>();
        Options opt = new Options();
        boolean cli = false;
        for (int i = 0; i < args.length; i++) {
            String a = args[i];
            if ("--cli".equals(a)) cli = true;
            else if ("--pictures".equals(a)) opt.pictures = true;
            else if ("--no-copy".equals(a)) opt.copy = false;
            else if ("--format".equals(a) && i + 1 < args.length) opt.format = args[++i].toLowerCase(Locale.ROOT).replace("jpeg", "jpg");
            else if ("--dpi".equals(a) && i + 1 < args.length) opt.dpi = Integer.parseInt(args[++i]);
            else files.add(new File(a));
        }
        if (cli) System.exit(runCli(files, opt));

        SwingUtilities.invokeLater(new Runnable() {
            public void run() { new Window(files).setVisible(true); }
        });
    }

    static int runCli(List<File> files, Options opt) {
        String password = System.getenv("UNLOCK_PDF_PASSWORD");
        int bad = 0;
        for (File f : collectPdfs(files)) {
            Result r = process(f, password, opt, null);
            StringBuilder line = new StringBuilder(r.status.name()).append('\t').append(f.getPath());
            if (r.copy != null) line.append("\tcopy=").append(r.copy.getPath());
            if (r.picturesDir != null) line.append("\tpictures=").append(r.pictures).append('\t').append(r.picturesDir.getPath());
            if (r.copy == null && r.picturesDir == null) line.append('\t').append(r.detail);
            System.out.println(line);
            if (r.status != Status.DONE && r.status != Status.NOT_PROTECTED) bad++;
        }
        return bad == 0 ? 0 : 1;
    }

    // ------------------------------------------------------------------------------------------
    // Window: one row per PDF, each with its own password and its own PDF / Pictures buttons.
    // ------------------------------------------------------------------------------------------

    static final int COL_FILE = 0, COL_PASSWORD = 1, COL_STATUS = 2, COL_RESULT = 3, COL_PDF = 4, COL_PICTURES = 5;

    static final class Row {
        final File file;
        Status status = Status.CHECKING;
        String detail = "";
        String password = "";   // this file's own password; empty = use the one for all files
        File copy, picturesDir;
        boolean busy;           // queued or running
        // Set once by the check when the file is added; the status changes later, these do not.
        boolean notProtected;   // no password, no restrictions: nothing to unlock (pictures still work)
        boolean unreadable;     // not a PDF PDFBox can open
        Row(File file) { this.file = file; }

        /** An unlocked copy exists, or none can be made because the PDF is not protected. */
        boolean copyDone() { return copy != null || notProtected; }
        boolean picturesDone() { return picturesDir != null; }
    }

    static final class Model extends AbstractTableModel {
        final List<Row> rows = new ArrayList<Row>();
        private final String[] cols = { "File", "Password", "Status", "Result", "", "" };

        public int getRowCount() { return rows.size(); }
        public int getColumnCount() { return cols.length; }
        @Override public String getColumnName(int c) { return cols[c]; }
        @Override public boolean isCellEditable(int r, int c) { return c == COL_PASSWORD && !rows.get(r).busy; }
        public Object getValueAt(int r, int c) {
            Row row = rows.get(r);
            switch (c) {
                case COL_FILE: return row.file.getName();
                case COL_PASSWORD: return row.password;
                case COL_STATUS: return row.status.label;
                case COL_RESULT: return row.detail;
                case COL_PDF: return "PDF";
                default: return "Pictures";
            }
        }
        @Override public void setValueAt(Object v, int r, int c) {
            if (c == COL_PASSWORD) { rows.get(r).password = v == null ? "" : String.valueOf(v); fireTableRowsUpdated(r, r); }
        }

        boolean add(File f) {
            for (Row r : rows) if (r.file.equals(f)) return false;
            rows.add(new Row(f));
            fireTableRowsInserted(rows.size() - 1, rows.size() - 1);
            return true;
        }

        void changed(Row row) {
            int i = rows.indexOf(row);
            if (i >= 0) fireTableRowsUpdated(i, i);
        }
    }

    static final class Window extends JFrame {
        final Model model = new Model();
        private final JTable table;
        final JPasswordField sharedPassword = new JPasswordField(16);
        private final JComboBox<String> formatBox = new JComboBox<String>(new String[] { "PNG", "JPG" });
        private final JComboBox<String> dpiBox = new JComboBox<String>(new String[] { "100 dpi", "150 dpi", "200 dpi", "300 dpi" });
        private final JLabel summary = new JLabel(" ");
        private final Preferences prefs = Preferences.userNodeForPackage(UnlockPdf.class);
        // One file at a time, in click order: rendering is CPU- and memory-heavy, and order is what
        // the user expects when queueing several buttons.
        private final ExecutorService worker = Executors.newSingleThreadExecutor(new ThreadFactory() {
            public Thread newThread(Runnable r) { Thread t = new Thread(r, "unlock-pdf-worker"); t.setDaemon(true); return t; }
        });

        Window(List<File> initial) {
            super("Unlock PDF");
            try { UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName()); } catch (Exception ignored) { }
            setDefaultCloseOperation(EXIT_ON_CLOSE);
            setIconImages(padlockIcons());

            table = new JTable(model) {
                @Override protected void paintComponent(Graphics g) {
                    super.paintComponent(g);
                    if (model.getRowCount() == 0) paintEmptyHint(g, this);
                }
            };
            table.setFillsViewportHeight(true);
            table.setRowHeight(28);
            table.putClientProperty("terminateEditOnFocusLost", Boolean.TRUE);
            int[] widths = { 300, 150, 140, 330, 70, 80 };
            for (int c = 0; c < widths.length; c++) table.getColumnModel().getColumn(c).setPreferredWidth(widths[c]);
            table.getColumnModel().getColumn(COL_PDF).setMaxWidth(80);
            table.getColumnModel().getColumn(COL_PICTURES).setMaxWidth(95);
            table.getColumnModel().getColumn(COL_FILE).setCellRenderer(new FileRenderer());
            table.getColumnModel().getColumn(COL_STATUS).setCellRenderer(new StatusRenderer());
            table.getColumnModel().getColumn(COL_PASSWORD).setCellRenderer(new PasswordRenderer());
            JPasswordField cellPassword = new JPasswordField();
            DefaultCellEditor passwordEditor = new DefaultCellEditor(cellPassword);
            passwordEditor.setClickCountToStart(1);
            table.getColumnModel().getColumn(COL_PASSWORD).setCellEditor(passwordEditor);
            ButtonRenderer buttons = new ButtonRenderer(model);
            table.getColumnModel().getColumn(COL_PDF).setCellRenderer(buttons);
            table.getColumnModel().getColumn(COL_PICTURES).setCellRenderer(buttons);
            table.addMouseListener(new MouseAdapter() {
                @Override public void mouseClicked(MouseEvent e) {
                    int r = table.rowAtPoint(e.getPoint()), c = table.columnAtPoint(e.getPoint());
                    if (r < 0) return;
                    Row row = model.rows.get(r);
                    if (c == COL_PDF && ButtonRenderer.enabled(row, COL_PDF)) run(row, true, false);
                    else if (c == COL_PICTURES && ButtonRenderer.enabled(row, COL_PICTURES)) run(row, false, true);
                    else if (e.getClickCount() == 2 && c != COL_PASSWORD) reveal(row.copy != null ? row.copy : row.picturesDir != null ? row.picturesDir : row.file);
                }
            });

            TransferHandler drop = new FileDrop();
            JScrollPane scroll = new JScrollPane(table);
            table.setTransferHandler(drop);
            scroll.setTransferHandler(drop);
            ((JComponent) getContentPane()).setTransferHandler(drop);

            JLabel title = new JLabel("Drop PDFs (or folders) below. Give each file its password - or one for all - then press PDF or Pictures on a row, or the buttons for all.");
            title.setBorder(BorderFactory.createEmptyBorder(10, 12, 8, 12));

            formatBox.setSelectedItem(prefs.get("format", "PNG"));
            dpiBox.setSelectedItem(prefs.get("dpi", "150 dpi"));
            formatBox.addActionListener(e -> prefs.put("format", String.valueOf(formatBox.getSelectedItem())));
            dpiBox.addActionListener(e -> prefs.put("dpi", String.valueOf(dpiBox.getSelectedItem())));

            final char echo = sharedPassword.getEchoChar();
            final JCheckBox show = new JCheckBox("Show");
            show.addActionListener(e -> sharedPassword.setEchoChar(show.isSelected() ? (char) 0 : echo));
            sharedPassword.setToolTipText("Used for every file whose own Password cell is empty");

            JButton allPdf = new JButton("All → unlocked PDF");
            allPdf.addActionListener(e -> runAll(true, false));
            JButton allPictures = new JButton("All → pictures");
            allPictures.addActionListener(e -> runAll(false, true));

            JButton add = new JButton("Add files...");
            add.addActionListener(e -> chooseFiles());
            JButton remove = new JButton("Remove");
            remove.addActionListener(e -> removeSelected());
            JButton clear = new JButton("Clear finished");
            clear.addActionListener(e -> clearFinished());

            JPanel shared = new JPanel(new FlowLayout(FlowLayout.LEFT, 8, 4));
            shared.add(new JLabel("Password for all files:"));
            shared.add(sharedPassword);
            shared.add(show);
            JLabel hint = new JLabel("(a file's own password wins)");
            hint.setForeground(new Color(120, 120, 120));
            shared.add(hint);
            JPanel batch = new JPanel(new FlowLayout(FlowLayout.LEFT, 8, 2));
            batch.add(allPdf);
            batch.add(allPictures);
            batch.add(new JLabel("   Pictures as:"));
            batch.add(formatBox);
            batch.add(dpiBox);
            JPanel left = new JPanel(new BorderLayout());
            left.add(shared, BorderLayout.NORTH);
            left.add(batch, BorderLayout.SOUTH);
            JPanel manage = new JPanel(new FlowLayout(FlowLayout.RIGHT, 8, 4));
            manage.add(add);
            manage.add(remove);
            manage.add(clear);
            JPanel bottom = new JPanel(new BorderLayout());
            bottom.setBorder(BorderFactory.createEmptyBorder(4, 6, 2, 6));
            bottom.add(left, BorderLayout.WEST);
            bottom.add(manage, BorderLayout.EAST);
            summary.setBorder(BorderFactory.createEmptyBorder(2, 12, 8, 12));
            summary.setForeground(new Color(90, 90, 90));
            JPanel south = new JPanel(new BorderLayout());
            south.add(bottom, BorderLayout.NORTH);
            south.add(summary, BorderLayout.SOUTH);

            add(title, BorderLayout.NORTH);
            add(scroll, BorderLayout.CENTER);
            add(south, BorderLayout.SOUTH);
            setSize(new Dimension(1100, 540));
            setLocationRelativeTo(null);

            addFiles(initial);
            updateSummary();
        }

        private Options pictureOptions() {
            Options o = new Options();
            o.format = "JPG".equals(formatBox.getSelectedItem()) ? "jpg" : "png";
            o.dpi = Integer.parseInt(String.valueOf(dpiBox.getSelectedItem()).replaceAll("\\D", ""));
            return o;
        }

        private void commitEdit() {
            if (table.isEditing() && table.getCellEditor() != null) table.getCellEditor().stopCellEditing();
        }

        /** New rows are only checked (needs a password? restrictions only? not protected?). */
        private void addFiles(List<File> dropped) {
            int added = 0;
            for (File f : collectPdfs(dropped)) {
                if (!model.add(f)) continue;
                added++;
                final Row row = model.rows.get(model.rows.size() - 1);
                row.busy = true;
                worker.submit(new Runnable() {
                    public void run() {
                        final Status s = probe(row.file);
                        SwingUtilities.invokeLater(new Runnable() {
                            public void run() {
                                row.busy = false;
                                row.status = s;
                                row.notProtected = s == Status.NOT_PROTECTED;
                                row.unreadable = s == Status.ERROR;
                                row.detail = s == Status.NEEDS_PASSWORD ? "type its password, or use the one for all files"
                                        : s == Status.NO_PASSWORD_NEEDED ? "only restrictions - PDF or Pictures work right away"
                                        : s == Status.NOT_PROTECTED ? "not protected - Pictures still works"
                                        : "not a readable PDF";
                                model.changed(row);
                                updateSummary();
                            }
                        });
                    }
                });
            }
            if (!dropped.isEmpty() && added == 0) summary.setText("No new PDF files in what was dropped.");
        }

        /** Queues one file: an unlocked PDF and/or its pictures, with its own (or the shared) password. */
        void run(final Row row, final boolean copy, final boolean pictures) {
            commitEdit();
            if (row.busy) return;
            final Options opt = pictureOptions();
            opt.copy = copy;
            opt.pictures = pictures;
            final String pw = !row.password.isEmpty() ? row.password : new String(sharedPassword.getPassword());
            row.busy = true;
            row.status = Status.WORKING;
            row.detail = "waiting in line...";
            model.changed(row);
            worker.submit(new Runnable() {
                public void run() {
                    final Result res = UnlockPdf.process(row.file, pw, opt, new Progress() {
                        public void update(final String what) {
                            SwingUtilities.invokeLater(new Runnable() { public void run() { row.detail = what; model.changed(row); } });
                        }
                    });
                    SwingUtilities.invokeLater(new Runnable() {
                        public void run() {
                            row.busy = false;
                            if (res.copy != null) row.copy = res.copy;
                            if (res.picturesDir != null) row.picturesDir = res.picturesDir;
                            if (res.status == Status.DONE || res.status == Status.NOT_PROTECTED) {
                                row.status = (row.copy != null || row.picturesDir != null) ? Status.DONE : res.status;
                                row.detail = describe(row, res);
                            } else {
                                row.status = res.status;
                                row.detail = res.detail;
                            }
                            model.changed(row);
                            updateSummary();
                        }
                    });
                }
            });
        }

        /** Everything this row has produced so far. */
        private String describe(Row row, Result last) {
            StringBuilder sb = new StringBuilder();
            if (row.copy != null) sb.append(row.copy.getName());
            if (row.picturesDir != null) {
                if (sb.length() > 0) sb.append("  +  ");
                File[] files = row.picturesDir.listFiles();
                int n = files == null ? 0 : files.length;
                sb.append(n).append(n == 1 ? " picture in " : " pictures in ").append(row.picturesDir.getName());
            }
            if (sb.length() == 0) sb.append(last.detail);
            return sb.toString();
        }

        void runAll(boolean copy, boolean pictures) {
            commitEdit();
            int queued = 0;
            for (Row r : model.rows) {
                if (r.busy || r.unreadable) continue;
                if (copy && !r.copyDone()) { run(r, true, false); queued++; }
                else if (pictures && !r.picturesDone()) { run(r, false, true); queued++; }
            }
            if (queued == 0) summary.setText(copy ? "Every file already has its unlocked PDF (or is not protected)." : "Every file already has its pictures.");
        }

        private void updateSummary() {
            int done = 0, waiting = 0, failed = 0;
            for (Row r : model.rows) {
                if (r.status == Status.DONE) done++;
                else if (r.status == Status.ERROR) failed++;
                else if (r.status == Status.NEEDS_PASSWORD || r.status == Status.WRONG_PASSWORD) waiting++;
            }
            if (model.rows.isEmpty()) summary.setText("Everything is saved next to the originals: \"name (unlocked).pdf\" and \"name (pages)\". Double-click a row to show it.");
            else summary.setText(model.rows.size() + " file(s): " + done + " done, " + waiting + " waiting for a password"
                    + (failed > 0 ? ", " + failed + " failed" : "") + ".   Double-click a row to show the result.");
        }

        private void chooseFiles() {
            JFileChooser fc = new JFileChooser();
            fc.setMultiSelectionEnabled(true);
            fc.setFileSelectionMode(JFileChooser.FILES_AND_DIRECTORIES);
            fc.setFileFilter(new FileNameExtensionFilter("PDF files", "pdf"));
            if (fc.showOpenDialog(this) == JFileChooser.APPROVE_OPTION) {
                List<File> picked = new ArrayList<File>();
                for (File f : fc.getSelectedFiles()) picked.add(f);
                addFiles(picked);
            }
        }

        private void removeSelected() {
            commitEdit();
            int[] sel = table.getSelectedRows();
            for (int i = sel.length - 1; i >= 0; i--) if (!model.rows.get(sel[i]).busy) model.rows.remove(sel[i]);
            model.fireTableDataChanged();
            updateSummary();
        }

        private void clearFinished() {
            commitEdit();
            for (int i = model.rows.size() - 1; i >= 0; i--) if (model.rows.get(i).status == Status.DONE && !model.rows.get(i).busy) model.rows.remove(i);
            model.fireTableDataChanged();
            updateSummary();
        }

        /** Drops from Explorer/Finder (file lists) and Linux file managers (text/uri-list). */
        final class FileDrop extends TransferHandler {
            private final DataFlavor uriList = uriListFlavor();

            @Override public boolean canImport(TransferSupport s) {
                return s.isDataFlavorSupported(DataFlavor.javaFileListFlavor) || (uriList != null && s.isDataFlavorSupported(uriList));
            }

            @Override @SuppressWarnings("unchecked")
            public boolean importData(TransferSupport s) {
                try {
                    Transferable t = s.getTransferable();
                    List<File> files = new ArrayList<File>();
                    if (t.isDataFlavorSupported(DataFlavor.javaFileListFlavor)) {
                        files.addAll((List<File>) t.getTransferData(DataFlavor.javaFileListFlavor));
                    } else if (uriList != null && t.isDataFlavorSupported(uriList)) {
                        for (String line : ((String) t.getTransferData(uriList)).split("\r?\n")) {
                            line = line.trim();
                            if (line.startsWith("file:")) files.add(new File(new URI(line)));
                        }
                    }
                    addFiles(files);
                    return true;
                } catch (Exception e) {
                    summary.setText("Could not read the dropped files: " + e.getMessage());
                    return false;
                }
            }
        }
    }

    private static DataFlavor uriListFlavor() {
        try { return new DataFlavor("text/uri-list;class=java.lang.String"); } catch (ClassNotFoundException e) { return null; }
    }

    // ------------------------------------------------------------------------------------------
    // Cell renderers
    // ------------------------------------------------------------------------------------------

    /** The row buttons: drawn as real buttons, clicks handled by the table's mouse listener. */
    static final class ButtonRenderer implements TableCellRenderer {
        private final Model model;
        private final JButton button = new JButton();
        ButtonRenderer(Model model) { this.model = model; button.setFocusable(false); button.setMargin(new java.awt.Insets(1, 4, 1, 4)); }

        static boolean enabled(Row row, int column) {
            if (row.busy || row.status == Status.CHECKING || row.unreadable) return false;
            // An unprotected PDF has nothing to unlock; Pictures still works for it.
            if (column == COL_PDF && row.notProtected) return false;
            return true;
        }

        public Component getTableCellRendererComponent(JTable t, Object v, boolean sel, boolean focus, int r, int c) {
            Row row = model.rows.get(r);
            button.setText(String.valueOf(v));
            button.setEnabled(enabled(row, c));
            boolean has = c == COL_PDF ? row.copy != null : row.picturesDir != null;
            button.setToolTipText(c == COL_PDF ? "Save an unlocked copy of this PDF" : "Save every page of this PDF as a picture");
            button.setFont(button.getFont().deriveFont(has ? Font.PLAIN : Font.BOLD));
            return button;
        }
    }

    static final class PasswordRenderer extends DefaultTableCellRenderer {
        @Override public Component getTableCellRendererComponent(JTable t, Object v, boolean sel, boolean focus, int r, int c) {
            String pw = v == null ? "" : String.valueOf(v);
            super.getTableCellRendererComponent(t, pw.isEmpty() ? "click to type" : repeat('•', Math.min(pw.length(), 12)), sel, focus, r, c);
            setFont(getFont().deriveFont(pw.isEmpty() ? Font.ITALIC : Font.PLAIN));
            if (!sel) setForeground(pw.isEmpty() ? new Color(150, 150, 150) : Color.BLACK);
            return this;
        }
    }

    static final class FileRenderer extends DefaultTableCellRenderer {
        @Override public Component getTableCellRendererComponent(JTable t, Object v, boolean sel, boolean focus, int r, int c) {
            super.getTableCellRendererComponent(t, v, sel, focus, r, c);
            Row row = ((Model) t.getModel()).rows.get(t.convertRowIndexToModel(r));
            setToolTipText(row.file.getAbsolutePath());
            return this;
        }
    }

    static final class StatusRenderer extends DefaultTableCellRenderer {
        StatusRenderer() { setHorizontalAlignment(SwingConstants.LEFT); }
        @Override public Component getTableCellRendererComponent(JTable t, Object v, boolean sel, boolean focus, int r, int c) {
            Component comp = super.getTableCellRendererComponent(t, v, sel, focus, r, c);
            if (!sel) {
                String s = String.valueOf(v);
                if (s.equals(Status.DONE.label)) comp.setForeground(new Color(0, 128, 0));
                else if (s.equals(Status.WRONG_PASSWORD.label) || s.equals(Status.NEEDS_PASSWORD.label)) comp.setForeground(new Color(190, 110, 0));
                else if (s.equals(Status.ERROR.label)) comp.setForeground(new Color(190, 0, 0));
                else if (s.equals(Status.WORKING.label) || s.equals(Status.CHECKING.label)) comp.setForeground(new Color(0, 90, 170));
                else comp.setForeground(new Color(100, 100, 100));
            }
            setFont(getFont().deriveFont(Font.BOLD));
            return comp;
        }
    }

    static String repeat(char ch, int n) {
        StringBuilder sb = new StringBuilder(n);
        for (int i = 0; i < n; i++) sb.append(ch);
        return sb.toString();
    }

    static void paintEmptyHint(Graphics g, JComponent c) {
        Graphics2D g2 = (Graphics2D) g.create();
        g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g2.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
        int w = c.getWidth(), h = c.getHeight();
        g2.setColor(new Color(170, 170, 170));
        g2.setStroke(new BasicStroke(2f, BasicStroke.CAP_ROUND, BasicStroke.JOIN_ROUND, 10f, new float[] { 8f, 6f }, 0f));
        g2.draw(new RoundRectangle2D.Float(16, 16, w - 32, h - 32, 18, 18));
        g2.drawImage(padlock(64), w / 2 - 32, h / 2 - 70, null);
        g2.setFont(c.getFont().deriveFont(Font.PLAIN, 18f));
        String msg = "Drop PDF files or folders here";
        int tw = g2.getFontMetrics().stringWidth(msg);
        g2.setColor(new Color(120, 120, 120));
        g2.drawString(msg, (w - tw) / 2, h / 2 + 24);
        g2.dispose();
    }

    static void reveal(File f) {
        try {
            String os = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
            if (os.contains("win")) new ProcessBuilder("explorer.exe", "/select," + f.getAbsolutePath()).start();
            else if (os.contains("mac")) new ProcessBuilder("open", "-R", f.getAbsolutePath()).start();
            else Desktop.getDesktop().open(f.getAbsoluteFile().getParentFile());
        } catch (Exception ignored) { }
    }

    // ------------------------------------------------------------------------------------------
    // Padlock icon, drawn in code so the jar carries no image files and looks the same everywhere.
    // ------------------------------------------------------------------------------------------

    static List<Image> padlockIcons() {
        List<Image> icons = new ArrayList<Image>();
        for (int s : new int[] { 16, 24, 32, 48, 64, 128, 256 }) icons.add(padlock(s));
        return icons;
    }

    static BufferedImage padlock(int size) {
        BufferedImage img = new BufferedImage(size, size, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setRenderingHint(RenderingHints.KEY_STROKE_CONTROL, RenderingHints.VALUE_STROKE_PURE);
        float s = size;
        // Shackle, drawn open to say "unlock": the right leg lifted out of the body.
        g.setColor(new Color(120, 124, 132));
        g.setStroke(new BasicStroke(s * 0.11f, BasicStroke.CAP_ROUND, BasicStroke.JOIN_ROUND));
        int arcX = Math.round(s * 0.26f), arcY = Math.round(s * 0.06f), arcW = Math.round(s * 0.48f), arcH = Math.round(s * 0.48f);
        g.drawArc(arcX, arcY, arcW, arcH, 0, 180);
        g.drawLine(arcX, arcY + arcH / 2, arcX, Math.round(s * 0.48f));
        g.drawLine(arcX + arcW, arcY + arcH / 2, arcX + arcW, Math.round(s * 0.36f));
        // Body
        RoundRectangle2D body = new RoundRectangle2D.Float(s * 0.14f, s * 0.44f, s * 0.72f, s * 0.50f, s * 0.14f, s * 0.14f);
        g.setPaint(new java.awt.GradientPaint(0, s * 0.44f, new Color(255, 205, 64), 0, s * 0.94f, new Color(222, 150, 20)));
        g.fill(body);
        g.setColor(new Color(176, 112, 10));
        g.setStroke(new BasicStroke(Math.max(1f, s * 0.025f)));
        g.draw(body);
        // Keyhole
        g.setColor(new Color(110, 70, 8));
        float kh = s * 0.11f;
        g.fill(new java.awt.geom.Ellipse2D.Float(s * 0.5f - kh / 2, s * 0.58f, kh, kh));
        g.fill(new java.awt.geom.Rectangle2D.Float(s * 0.5f - kh * 0.22f, s * 0.64f, kh * 0.44f, s * 0.15f));
        g.dispose();
        return img;
    }
}
