import SwiftUI

struct OCRPreviewView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Human-Readable Text")
                .font(.headline)

            ScrollView {
                Text(text.isEmpty ? "No text was detected in this screenshot." : text)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(minHeight: 140)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
