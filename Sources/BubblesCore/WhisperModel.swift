import Foundation

/// The built-in Whisper's model: `ggml-large-v3-turbo-q5_0.bin` (MIT, Hugging Face `ggerganov/whisper.cpp`).
/// `make app` puts it into `Bubbles.app/Contents/Resources/Models`; a build without it offers "Download model",
/// which saves it to Application Support. The checksum is the one `scripts/fetch-whisper.sh` pins.
public enum WhisperModel {
    public static let fileName = "ggml-large-v3-turbo-q5_0.bin"
    public static let downloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    public static let sha256 = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    public static let byteCount: Int64 = 574_041_195

    /// `~/Library/Application Support/Bubbles/Models/ggml-large-v3-turbo-q5_0.bin` (or under `BUBBLES_DATA_DIR`).
    public static var defaultDownloadedURL: URL {
        DataFolder.url.appendingPathComponent("Models", isDirectory: true).appendingPathComponent(fileName)
    }

    /// The model in the app's resources, else the downloaded one, else nil.
    public static func locate(resources: URL?, downloaded: URL = defaultDownloadedURL,
                              exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        if let bundled = resources?.appendingPathComponent("Models").appendingPathComponent(fileName), exists(bundled) {
            return bundled
        }
        return exists(downloaded) ? downloaded : nil
    }
}
