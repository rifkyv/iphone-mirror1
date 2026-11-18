import ReplayKit
import SwiftUI

struct ContentView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("iPhone Mirror")
                    .font(.largeTitle.bold())
                Text("Mirroring layar + suara game ke PC lewat kabel USB.")
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    step("1", "Colok iPhone ke PC pakai kabel USB.")
                    step("2", "Di PC, jalankan run.bat lalu klik Mulai Mirroring.")
                    step("3", "Tekan tombol merah di bawah, pilih iPhone Mirror, lalu Start Broadcast.")
                    step("4", "Buka game. Layar dan suaranya langsung muncul di PC.")
                }

                HStack {
                    Spacer()
                    BroadcastButton()
                        .frame(width: 90, height: 90)
                    Spacer()
                }
                .padding(.vertical, 8)

                Text("Bitrate, resolusi, dan frame rate diatur dari aplikasi di PC. Untuk berhenti, ketuk indikator merah di pojok atas layar, lalu Stop.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(24)
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.headline)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.red.opacity(0.15)))
            Text(text)
        }
    }
}

/// The system "start broadcast" button, preset to our extension.
struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 90, height: 90))
        picker.showsMicrophoneButton = false
        if let appID = Bundle.main.bundleIdentifier {
            picker.preferredExtension = appID + ".broadcast"
        }
        for case let button as UIButton in picker.subviews {
            button.imageView?.tintColor = .systemRed
        }
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
