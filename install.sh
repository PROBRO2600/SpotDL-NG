#!/bin/bash

set -e

echo "=== Starting SpotDL-NG All-in-One Installation ==="

# 1. Install System Dependencies & Python GTK Bindings / Venv support
echo "Installing system dependencies..."
if command -v apt &> /dev/null; then
    sudo apt update
    sudo apt install -y ffmpeg python3-full python3-venv python3-gi python3-gi-cairo gir1.2-gtk-4.0 gir1.2-adw-1 curl
elif command -v dnf &> /dev/null; then
    sudo dnf install -y ffmpeg python3-devel python3-virtualenv gtk4 libadwaita curl
elif command -v pacman &> /dev/null; then
    sudo pacman -S --noconfirm ffmpeg python python-virtualenv python-gobject gtk4 libadwaita curl
else
    echo "Warning: Unsupported package manager. Ensure ffmpeg, python3-venv, and gtk4 are installed."
fi

# 2. Install Deno
echo "Installing Deno..."
if ! command -v deno &> /dev/null; then
    curl -fsSL https://deno.land/install.sh | sh
else
    echo "Deno is already installed."
fi

# 3. Create Application Directory & Virtual Environment
INSTALL_DIR="$HOME/.local/share/spotdl-ng"
echo "Setting up Python virtual environment at $INSTALL_DIR/venv..."
mkdir -p "$INSTALL_DIR"

if [ -f "./icon.png" ]; then
    cp "./icon.png" "$INSTALL_DIR/icon.png"
    echo "Custom icon.png copied to $INSTALL_DIR/icon.png"
else
    echo "Notice: icon.png not found in current directory. Using default app icon."
fi

python3 -m venv --system-site-packages "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install spotdl

# 4. Generate spotdl.py automatically
echo "Creating application script..."
cat << 'EOF' > "$INSTALL_DIR/spotdl.py"
from pathlib import Path
import threading
import subprocess
import platform
import socket
import signal
import os
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")

from gi.repository import Adw, Gtk, GLib, Gdk

GLib.set_prgname("com.example.SpotDLNG")
GLib.set_application_name("SpotDL-NG")

FORMATS = ["mp3", "flac", "m4a", "opus", "ogg", "wav"]
BITRATES = ["32k", "64k", "96k", "128k", "192k", "256k", "320k", "auto"]
AUDIO_PROVIDERS = ["youtube-music", "youtube", "piped", "soundcloud", "bandcamp"]
LYRICS_PROVIDERS = ["genius", "musixmatch", "azlyrics", "synced"]


def check_internet_connection(host="8.8.8.8", port=53, timeout=3):
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect((host, port))
            return True
    except OSError:
        return False


class SpotDLWindow(Adw.ApplicationWindow):

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

        self.set_title("SpotDL-NG")
        self.set_default_size(520, 750)

        self.connect("close-request", self.on_close_request)

        self.download_path = Path.home() / "Music"
        self.is_downloading = False
        self.download_thread = None
        self.current_process = None

        self.audio_provider_switches = {}
        self.lyrics_provider_switches = {}

        self.build_ui()
        GLib.idle_add(self.check_launch_network)

    def on_close_request(self, window):
        if self.is_downloading:
            self.is_downloading = False
            self.log_message("Window closing. Terminating active downloads...")
            self.kill_current_process()
        return False

    def kill_current_process(self):
        proc = self.current_process
        if proc and proc.poll() is None:
            try:
                if platform.system() != "Windows":
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                else:
                    proc.terminate()
            except Exception as e:
                print(f"Error terminating process: {e}")

    def check_launch_network(self):
        if not check_internet_connection():
            self.show_network_dialog(
                "Network Unavailable",
                "No active internet connection was detected on launch. Please check your network settings."
            )

    def show_network_dialog(self, title, message):
        def present_dialog():
            try:
                dialog = Adw.MessageDialog.new(self, title, message)
                dialog.add_response("ok", "OK")
                dialog.connect("response", lambda d, response: d.destroy())
                dialog.present()
            except Exception as e:
                print(f"Network dialog error: {e}")
            return False
        GLib.idle_add(present_dialog)

    def show_empty_queue_dialog(self):
        def present_dialog():
            try:
                dialog = Adw.MessageDialog.new(
                    self,
                    "Queue is empty",
                    "Queue is empty. Add links or search queries first!"
                )
                dialog.add_response("ok", "OK")
                dialog.connect("response", lambda d, response: d.destroy())
                dialog.present()
            except Exception as e:
                print(f"Empty queue dialog error: {e}")
            return False
        GLib.idle_add(present_dialog)

    def build_ui(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)

        header = Adw.HeaderBar()
        header_title = Adw.WindowTitle(
            title="SpotDL-NG",
            subtitle="Music downloader",
        )
        header.set_title_widget(header_title)

        pra_label = Gtk.Label(label="Pra")
        pra_label.add_css_class("dim-label")
        pra_label.set_margin_start(10)
        header.pack_start(pra_label)

        root.append(header)

        scrolled_window = Gtk.ScrolledWindow()
        scrolled_window.set_vexpand(True)
        scrolled_window.set_hexpand(True)
        scrolled_window.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        content.set_margin_start(20)
        content.set_margin_end(20)
        content.set_margin_top(20)
        content.set_margin_bottom(20)

        title = Gtk.Label(label="SpotDL-NG", xalign=0)
        title.add_css_class("title-2")
        content.append(title)

        subtitle = Gtk.Label(label="Paste a Spotify link or enter a search query.", xalign=0)
        subtitle.add_css_class("dim-label")
        content.append(subtitle)

        input_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)

        self.url_entry = Gtk.Entry()
        self.url_entry.set_hexpand(True)
        self.url_entry.set_placeholder_text("Spotify URL or search query")
        self.url_entry.connect("activate", self.add_item)
        input_box.append(self.url_entry)

        add_button = Gtk.Button(label="Add")
        add_button.add_css_class("suggested-action")
        add_button.connect("clicked", self.add_item)
        input_box.append(add_button)

        content.append(input_box)

        queue_label = Gtk.Label(label="Queue", xalign=0)
        queue_label.add_css_class("heading")
        queue_label.set_margin_top(8)
        content.append(queue_label)

        queue_frame = Gtk.Frame()
        queue_frame.set_vexpand(True)

        scroll = Gtk.ScrolledWindow()
        scroll.set_min_content_height(180)

        self.queue = Gtk.ListBox()
        self.queue.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.queue.add_css_class("boxed-list")

        scroll.set_child(self.queue)
        queue_frame.set_child(scroll)
        content.append(queue_frame)

        queue_controls = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)

        remove_button = Gtk.Button(label="Remove")
        remove_button.connect("clicked", self.remove_selected)
        queue_controls.append(remove_button)

        clear_button = Gtk.Button(label="Clear")
        clear_button.connect("clicked", self.clear_queue)
        queue_controls.append(clear_button)

        content.append(queue_controls)

        settings = Adw.PreferencesGroup()
        settings.set_title("Download settings")

        folder_row = Adw.ActionRow()
        folder_row.set_title("Download folder")

        self.folder_button = Gtk.Button(label=str(self.download_path))
        self.folder_button.set_valign(Gtk.Align.CENTER)
        self.folder_button.connect("clicked", self.choose_folder)
        folder_row.add_suffix(self.folder_button)
        settings.add(folder_row)

        format_row = Adw.ComboRow()
        format_row.set_title("Format")
        format_row.set_model(Gtk.StringList.new(FORMATS))
        format_row.set_selected(0)
        self.format_row = format_row
        settings.add(format_row)

        bitrate_row = Adw.ComboRow()
        bitrate_row.set_title("Bitrate")
        bitrate_row.set_model(Gtk.StringList.new(BITRATES))
        bitrate_row.set_selected(7)
        self.bitrate_row = bitrate_row
        settings.add(bitrate_row)

        audio_expander = Adw.ExpanderRow()
        audio_expander.set_title("Audio Providers")

        for provider in AUDIO_PROVIDERS:
            row = Adw.SwitchRow()
            row.set_title(provider)
            if provider == "youtube-music":
                row.set_active(True)
            self.audio_provider_switches[provider] = row
            audio_expander.add_row(row)

        settings.add(audio_expander)

        threads_row = Adw.SpinRow.new_with_range(1, 32, 1)
        threads_row.set_title("Threads")
        threads_row.set_value(10)
        self.threads_row = threads_row
        settings.add(threads_row)

        lyrics_row = Adw.SwitchRow()
        lyrics_row.set_title("Download lyrics")
        lyrics_row.set_active(True)
        self.lyrics_row = lyrics_row
        settings.add(lyrics_row)

        lrc_row = Adw.SwitchRow()
        lrc_row.set_title("Generate lyric files")
        lrc_row.set_active(True)
        self.lrc_row = lrc_row
        settings.add(lrc_row)

        lyrics_expander = Adw.ExpanderRow()
        lyrics_expander.set_title("Lyrics Providers")

        for provider in LYRICS_PROVIDERS:
            row = Adw.SwitchRow()
            row.set_title(provider)
            if provider == "genius":
                row.set_active(True)
            self.lyrics_provider_switches[provider] = row
            lyrics_expander.add_row(row)

        settings.add(lyrics_expander)

        overwrite_row = Adw.ComboRow()
        overwrite_row.set_title("Existing files")
        overwrite_row.set_model(Gtk.StringList.new(["Skip", "Overwrite", "Metadata only"]))
        overwrite_row.set_selected(0)
        self.overwrite_row = overwrite_row
        settings.add(overwrite_row)

        content.append(settings)

        self.status_label = Gtk.Label(label="Completed", xalign=0)
        self.status_label.set_margin_top(8)
        content.append(self.status_label)

        self.overall_progress = Gtk.ProgressBar()
        self.overall_progress.set_pulse_step(0.02)

        css_provider = Gtk.CssProvider()
        css_provider.load_from_data(b"progressbar progress { transition: none; }")
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        content.append(self.overall_progress)

        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)

        self.download_button = Gtk.Button(label="Download")
        self.download_button.add_css_class("suggested-action")
        self.download_button.add_css_class("pill")
        self.download_button.connect("clicked", self.start_download)
        buttons.append(self.download_button)

        self.stop_button = Gtk.Button(label="Stop")
        self.stop_button.add_css_class("pill")
        self.stop_button.set_sensitive(False)
        self.stop_button.connect("clicked", self.stop_download)
        buttons.append(self.stop_button)

        open_button = Gtk.Button(label="Open")
        open_button.add_css_class("pill")
        open_button.connect("clicked", self.open_folder_target)
        buttons.append(open_button)

        content.append(buttons)

        expander = Gtk.Expander(label="Show log")

        log_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        log_box.set_margin_top(8)

        clear_log_button = Gtk.Button(label="Clear Log")
        clear_log_button.set_halign(Gtk.Align.END)
        clear_log_button.connect("clicked", self.clear_log)
        log_box.append(clear_log_button)

        log_scroll = Gtk.ScrolledWindow()
        log_scroll.set_min_content_height(150)

        self.log_view = Gtk.TextView()
        self.log_view.set_editable(False)
        self.log_view.set_monospace(True)
        self.log_buffer = self.log_view.get_buffer()

        log_scroll.set_child(self.log_view)
        log_box.append(log_scroll)
        expander.set_child(log_box)

        content.append(expander)

        scrolled_window.set_child(content)
        root.append(scrolled_window)
        self.set_content(root)

    def get_selected_providers(self, provider_dict):
        return [name for name, switch in provider_dict.items() if switch.get_active()]

    def log_message(self, text):
        def update():
            try:
                end_iter = self.log_buffer.get_end_iter()
                self.log_buffer.insert(end_iter, text + "\n")
                mark = self.log_buffer.create_mark(None, end_iter, False)
                self.log_view.scroll_to_mark(mark, 0.0, True, 0.0, 1.0)
            except Exception as e:
                print(f"Logging error: {e}")
            return False
        GLib.idle_add(update)

    def clear_log(self, widget):
        start = self.log_buffer.get_start_iter()
        end = self.log_buffer.get_end_iter()
        self.log_buffer.delete(start, end)
        self.log_message("Log cleared.")

    def open_folder_target(self, widget):
        try:
            self.download_path.mkdir(parents=True, exist_ok=True)
            path_str = str(self.download_path)

            if platform.system() == "Windows":
                os.startfile(path_str)
            elif platform.system() == "Darwin":
                subprocess.Popen(["open", path_str])
            else:
                subprocess.Popen(["xdg-open", path_str])

            self.log_message(f"Opened target directory: {path_str}")
        except Exception as e:
            self.log_message(f"Failed to open directory: {e}")

    def add_item(self, widget):
        text = self.url_entry.get_text().strip()
        if not text:
            return

        row = Gtk.ListBoxRow()
        label = Gtk.Label(label=text, xalign=0)
        label.set_margin_start(12)
        label.set_margin_end(12)
        label.set_margin_top(8)
        label.set_margin_bottom(8)
        row.set_child(label)

        self.queue.append(row)
        self.url_entry.set_text("")
        self.log_message(f"Added to queue: {text}")

    def remove_selected(self, widget):
        selected_row = self.queue.get_selected_row()
        if selected_row:
            child_label = selected_row.get_child()
            text = child_label.get_label() if child_label else "Item"
            self.queue.remove(selected_row)
            self.log_message(f"Removed from queue: {text}")

    def clear_queue(self, widget):
        while True:
            row = self.queue.get_row_at_index(0)
            if row is None:
                break
            self.queue.remove(row)
        self.log_message("Queue cleared.")

    def choose_folder(self, widget):
        try:
            dialog = Gtk.FileDialog()
            dialog.select_folder(self, None, self.on_folder_selected)
        except Exception as e:
            self.log_message(f"Failed to open folder dialog: {e}")

    def on_folder_selected(self, dialog, result):
        try:
            folder = dialog.select_folder_finish(result)
            if folder:
                self.download_path = Path(folder.get_path())
                self.folder_button.set_label(str(self.download_path))
                self.log_message(f"Download folder changed to: {self.download_path}")
        except Exception as e:
            self.log_message(f"Folder selection error: {e}")

    def start_download(self, widget):
        if self.is_downloading:
            return

        items = []
        idx = 0
        while True:
            row = self.queue.get_row_at_index(idx)
            if row is None:
                break
            child = row.get_child()
            if child:
                items.append(child.get_label())
            idx += 1

        if not items:
            self.log_message("Queue is empty. Add links or search queries first.")
            self.show_empty_queue_dialog()
            return

        if not check_internet_connection():
            self.show_network_dialog("Network Error", "Cannot start download. Please check your internet connection.")
            return

        try:
            self.download_path.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            self.log_message(f"Error creating download directory: {e}")
            return

        config = {
            "fmt": FORMATS[self.format_row.get_selected()],
            "bitrate": BITRATES[self.bitrate_row.get_selected()],
            "audio_providers": self.get_selected_providers(self.audio_provider_switches),
            "lyrics_providers": self.get_selected_providers(self.lyrics_provider_switches),
            "threads": int(self.threads_row.get_value()),
            "download_lyrics": self.lyrics_row.get_active(),
            "generate_lrc": self.lrc_row.get_active(),
        }

        self.is_downloading = True
        self.download_button.set_sensitive(False)
        self.stop_button.set_sensitive(True)
        self.status_label.set_text("Downloading...")

        def set_indeterminate():
            def update_bar():
                if not self.is_downloading:
                    return False
                self.overall_progress.pulse()
                return True
            GLib.timeout_add(40, update_bar)

        GLib.idle_add(set_indeterminate)

        self.download_thread = threading.Thread(
            target=self.run_spotdl_process,
            args=(items, config),
            daemon=True
        )
        self.download_thread.start()

    def run_spotdl_process(self, items, config):
        spotdl_bin = str(Path(__file__).parent / "venv" / "bin" / "spotdl")
        failed_items = []

        for item in items:
            if not self.is_downloading:
                break

            if not check_internet_connection():
                self.log_message("Network dropped during download session.")
                self.show_network_dialog("Network Lost", "Internet connection was lost. Batch stopped.")
                failed_items.append(item)
                break

            cmd = [
                spotdl_bin,
                "download",
                item,
                "--output", str(self.download_path),
                "--format", config["fmt"],
                "--bitrate", config["bitrate"],
                "--threads", str(config["threads"]),
            ]

            if config["audio_providers"]:
                cmd.extend(["--audio"] + config["audio_providers"])

            if config["lyrics_providers"]:
                cmd.extend(["--lyrics"] + config["lyrics_providers"])

            if config["generate_lrc"]:
                cmd.append("--generate-lrc")

            self.log_message(f"Running command: {' '.join(cmd)}")

            item_failed = False
            try:
                kwargs = {
                    "stdout": subprocess.PIPE,
                    "stderr": subprocess.STDOUT,
                    "text": True,
                    "bufsize": 1,
                }
                if platform.system() != "Windows":
                    kwargs["start_new_session"] = True

                self.current_process = subprocess.Popen(cmd, **kwargs)

                if self.current_process.stdout:
                    for line in self.current_process.stdout:
                        if not self.is_downloading:
                            break
                        line_str = line.strip()
                        if line_str:
                            self.log_message(line_str)
                            if "LookupError" in line_str or "No matching song" in line_str:
                                item_failed = True

                self.current_process.wait()

                if (self.current_process.returncode != 0 or item_failed) and self.is_downloading:
                    self.log_message(f"Warning: Item failed/encountered LookupError: {item}")
                    failed_items.append(item)

            except FileNotFoundError:
                self.log_message("Error: 'spotdl' binary not found in virtual environment.")
                failed_items.append(item)
                break
            except Exception as e:
                self.log_message(f"Subprocess error for '{item}': {e}")
                failed_items.append(item)
            finally:
                self.current_process = None

        if failed_items and self.is_downloading:
            failed_file_path = self.download_path / "failed_downloads.txt"
            try:
                with open(failed_file_path, "w", encoding="utf-8") as f:
                    f.write("\n".join(failed_items) + "\n")
                self.log_message(f"Saved failed downloads list to {failed_file_path}")
            except Exception as e:
                self.log_message(f"Failed to write log file: {e}")

            self.show_failed_dialog(failed_items)

        self.reset_ui_safe()

    def show_failed_dialog(self, failed_items):
        def present_dialog():
            try:
                body_text = "The following items failed or encountered an error:\n\n" + "\n".join(f"• {item}" for item in failed_items)
                dialog = Adw.MessageDialog.new(self, "Some Downloads Failed", body_text)
                dialog.add_response("ok", "OK")
                dialog.connect("response", lambda d, response: d.destroy())
                dialog.present()
            except Exception as e:
                print(f"Failed dialog error: {e}")
            return False
        GLib.idle_add(present_dialog)

    def reset_ui_safe(self):
        def update():
            self.is_downloading = False
            self.download_button.set_sensitive(True)
            self.stop_button.set_sensitive(False)
            self.status_label.set_text("Completed")
            self.overall_progress.set_fraction(1.0)
            self.log_message("Download queue processing completed.")
            return False
        GLib.idle_add(update)

    def stop_download(self, widget):
        self.is_downloading = False
        self.status_label.set_text("Stopping...")
        self.log_message("Stop requested by user. Terminating process...")
        self.kill_current_process()
        self.stop_button.set_sensitive(False)


class SpotDLApp(Adw.Application):

    def __init__(self):
        super().__init__(application_id="com.example.SpotDLNG")

    def do_activate(self):
        win = SpotDLWindow(application=self)
        win.present()


if __name__ == "__main__":
    app = SpotDLApp()
    app.run(None)
EOF

# 5. Create Desktop Shortcut Entry
DESKTOP_DIR="$HOME/.local/share/applications"
mkdir -p "$DESKTOP_DIR"
DESKTOP_FILE="$DESKTOP_DIR/com.example.SpotDLNG.desktop"

ICON_PATH="$INSTALL_DIR/icon.png"
if [ ! -f "$ICON_PATH" ]; then
    ICON_PATH="audio-x-generic"
fi

echo "Creating desktop shortcut at $DESKTOP_FILE..."
cat << EOF > "$DESKTOP_FILE"
[Desktop Entry]
Name=SpotDL-NG
Comment=Music downloader powered by spotdl and GTK4
Exec=env PATH="$HOME/.deno/bin:\$PATH" "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/spotdl.py"
Icon=$ICON_PATH
Terminal=false
Type=Application
Categories=AudioVideo;Audio;
StartupNotify=true
StartupWMClass=com.example.SpotDLNG
EOF

chmod +x "$DESKTOP_FILE"

if command -v update-desktop-database &> /dev/null; then
    update-desktop-database "$DESKTOP_DIR"
fi

# 6. Create Global Terminal Command 'spotdl-ng'
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
LAUNCHER="$BIN_DIR/spotdl-ng"

echo "Creating global command 'spotdl-ng' at $LAUNCHER..."
cat << EOF > "$LAUNCHER"
#!/bin/bash
export PATH="\$HOME/.deno/bin:\$PATH"
exec "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/spotdl.py" "\$@"
EOF

chmod +x "$LAUNCHER"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    if [ -f "$HOME/.zshrc" ]; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
    fi
fi

echo "=== Installation Completed Successfully! ==="
echo "You can now run 'spotdl-ng' in your terminal or find it in your app menu."
