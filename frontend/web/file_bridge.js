// Files in and out of the app in the browser: saving one the app has made (a
// PDF report) as a download, and reading a text file the person chooses (a
// trained model's registration).
//
// The Dart side is lib/core/files/file_saver_web.dart and
// lib/core/files/file_picker_web.dart.

// The largest file the app reads into memory.
const MAX_PICKED_BYTES = 12 * 1024 * 1024;

window.physioFiles = {
  save(bytes, filename, mimeType) {
    const url = URL.createObjectURL(new Blob([bytes], { type: mimeType }));
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    // Long enough for the download to start; after that the copy held in
    // memory is released.
    setTimeout(() => URL.revokeObjectURL(url), 60000);
  },

  // Opens the browser's own file chooser. Resolves with the chosen file's
  // name and text, with text null when the file is too large to read, or
  // with null when the person closes the chooser without choosing.
  pick(accept) {
    return new Promise((resolve) => {
      const input = document.createElement('input');
      input.type = 'file';
      input.accept = accept;
      input.style.display = 'none';
      input.addEventListener('change', async () => {
        const file = input.files[0];
        input.remove();
        if (!file) return resolve(null);
        if (file.size > MAX_PICKED_BYTES) return resolve({ name: file.name, text: null });
        resolve({ name: file.name, text: await file.text() });
      });
      input.addEventListener('cancel', () => {
        input.remove();
        resolve(null);
      });
      document.body.appendChild(input);
      input.click();
    });
  },
};
