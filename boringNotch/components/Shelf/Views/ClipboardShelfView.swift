//
//  ClipboardShelfView.swift
//  boringNotch
//
import SwiftUI

/// Temporary clipboard area, styled after the file shelf panel.
struct ClipboardShelfView: View {
    let animation: Animation?
    @ObservedObject private var clipboard = ClipboardManager.shared

    private let spacing: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                VStack(spacing: 8) {
                    header
                    content
                }
                .padding()
            }
            .transaction { transaction in
                transaction.animation = animation
            }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.gray)
            Text("Clipboard")
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.medium)
                .foregroundStyle(.gray)
            Spacer()
            Button {
                clipboard.clear()
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(.system(.caption, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(clipboard.entries.isEmpty ? .gray.opacity(0.5) : .white)
            .disabled(clipboard.entries.isEmpty)
        }
    }

    @ViewBuilder
    private var content: some View {
        if clipboard.entries.isEmpty {
            Text("Copied text shows up here")
                .foregroundStyle(.gray)
                .font(.system(.callout, design: .rounded))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: spacing) {
                    ForEach(clipboard.entries) { entry in
                        ClipboardEntryCard(entry: entry)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

private struct ClipboardEntryCard: View {
    let entry: ClipboardEntry
    @State private var justCopied = false

    /// Newlines would otherwise stretch the row; show the text as one line.
    private func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var body: some View {
        Button {
            ClipboardManager.shared.copy(entry)
            justCopied = true
            Task {
                try? await Task.sleep(for: .seconds(1))
                justCopied = false
            }
        } label: {
            HStack(spacing: 6) {
                Text(singleLine(entry.text))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if justCopied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove") { ClipboardManager.shared.remove(entry) }
        }
        .help("Click to copy again")
    }
}
