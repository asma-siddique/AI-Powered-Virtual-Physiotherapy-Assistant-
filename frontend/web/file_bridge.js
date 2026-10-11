// Saving a file the app has made (a PDF report) as a browser download.
//
// The Dart side is lib/core/files/file_saver_web.dart.

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
};
