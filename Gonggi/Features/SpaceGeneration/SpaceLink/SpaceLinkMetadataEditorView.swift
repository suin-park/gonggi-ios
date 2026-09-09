import SwiftUI

/// Optional hotspot name + external URL before create / when editing.
struct SpaceLinkMetadataEditorView: View {
    let title: String
    let confirmTitle: String
    @Binding var displayName: String
    @Binding var externalUrl: String
    @Binding var labelSize: SpaceLinkLabelSize
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @State private var urlError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("예: 작품 정보", text: $displayName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: displayName) { _, new in
                            if new.count > SpaceLinkExternalURL.maxDisplayNameLength {
                                displayName = String(new.prefix(SpaceLinkExternalURL.maxDisplayNameLength))
                            }
                        }
                } header: {
                    Text("핫스팟 이름 (선택)")
                }

                Section {
                    TextField("https://example.com", text: $externalUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                    if let urlError {
                        Text(urlError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("웹 주소 (선택)")
                } footer: {
                    Text("링크를 입력하면 공간을 보는 사람이 열어볼 수 있어요")
                }

                if showsLabelSizePicker {
                    Section("텍스트 크기") {
                        Picker("텍스트 크기", selection: $labelSize) {
                            ForEach(SpaceLinkLabelSize.allCases, id: \.self) { size in
                                Text(size.displayTitle).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { attemptConfirm() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var showsLabelSizePicker: Bool {
        SpaceLinkExternalURL.normalizeDisplayName(displayName) != nil
            || SpaceLinkExternalURL.hostname(from: externalUrl) != nil
    }

    private func attemptConfirm() {
        switch SpaceLinkExternalURL.normalize(externalUrl) {
        case .success(let normalized):
            urlError = nil
            if let normalized {
                externalUrl = normalized
            } else {
                externalUrl = ""
            }
            displayName = SpaceLinkExternalURL.normalizeDisplayName(displayName) ?? ""
            onConfirm()
        case .failure(let err):
            urlError = err.message
        }
    }
}
