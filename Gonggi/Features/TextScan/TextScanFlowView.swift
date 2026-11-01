import PhotosUI
import SwiftUI
import VisionKit

/// 글자 스캔 (Capture › Other): connect Google once, choose a sheet, then scan handwritten paper and add what it
/// says as rows under the sheet's column names. Every row is checked by the user before it is written.
@MainActor
struct TextScanFlowView: View {
    let onClose: () -> Void

    @ObservedObject private var google = TextScanGoogleAuth.shared
    @State private var stage: Stage = .start
    @State private var sheets: [TextScanSheet] = TextScanSheetStore.load()
    @State private var sheet: TextScanSheet?
    @State private var header: TextScanHeader?
    @State private var pages: [UIImage] = []
    @State private var rows: [TextScanEditableRow] = []
    @State private var busy = false
    @State private var error: String?
    @State private var showCamera = false
    @State private var showNewSheet = false
    @State private var showLink = false
    @State private var photoItems: [PhotosPickerItem] = []

    enum Stage: Equatable {
        case start
        case sheets
        case capture
        case review
        case saved(count: Int, firstRow: Int?)
    }

    static let maxPages = 4

    var body: some View {
        VStack(spacing: 0) {
            WhikCaptureTopBar(title: L("Text Scan"), onClose: onClose)
                .padding(.top, 20)
                .padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch stage {
                    case .start: connectStep
                    case .sheets: sheetsStep
                    case .capture: captureStep
                    case .review: reviewStep
                    case .saved(let count, let firstRow): savedStep(count: count, firstRow: firstRow)
                    }
                }
                .padding(.horizontal, WhikLayout.sideInset)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(WhikColors.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .overlay { if busy { busyOverlay } }
        .onAppear { if google.isConnected { stage = .sheets } }
        .fullScreenCover(isPresented: $showCamera) {
            TextScanDocumentCamera { scanned in
                showCamera = false
                pages = Array((pages + scanned).prefix(Self.maxPages))
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showNewSheet) {
            TextScanNewSheetForm { title, columns in
                showNewSheet = false
                run { try await createSheet(title: title, columns: columns) }
            }
        }
        .sheet(isPresented: $showLink) {
            TextScanLinkForm { link in
                showLink = false
                run { try await openLinkedSheet(link) }
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        pages = Array((pages + [image]).prefix(Self.maxPages))
                    }
                }
                photoItems = []
            }
        }
        .alert(L("Text Scan"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("OK"), role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Steps

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image("WhikPhotoTextScan")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityHidden(true)
            Text(L("Turn handwriting into sheet rows"))
                .font(WhikFont.title(24))
                .foregroundStyle(WhikColors.textPrimary)
            Text(L("Scan handwritten notes, forms or tables. WHIK reads them and adds them as rows to the Google Sheet you choose."))
                .font(WhikFont.body())
                .foregroundStyle(WhikColors.textSecondary)
            Text(L("WHIK only writes to the sheet you choose, and only after you check the rows."))
                .font(WhikFont.caption())
                .foregroundStyle(WhikColors.textTertiary)
            TextScanPrimaryButton(title: L("Connect Google account"), icon: "link") {
                run {
                    try await google.connect()
                    stage = .sheets
                }
            }
        }
        .padding(.top, 8)
    }

    private var sheetsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            accountRow
            Text(L("Choose a sheet"))
                .font(WhikFont.title(22))
                .foregroundStyle(WhikColors.textPrimary)
            Text(L("Rows are added under the column names in the first row of the sheet."))
                .font(WhikFont.subheadline())
                .foregroundStyle(WhikColors.textSecondary)
            if !sheets.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(sheets.enumerated()), id: \.element.id) { index, s in
                        if index > 0 { Rectangle().fill(WhikColors.border).frame(height: 1) }
                        Button {
                            run { try await select(s) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "tablecells")
                                    .foregroundStyle(WhikColors.mint)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title.isEmpty ? L("Untitled sheet") : s.title)
                                        .font(WhikFont.body(.semibold))
                                        .foregroundStyle(WhikColors.textPrimary)
                                        .lineLimit(1)
                                    Text(s.tab)
                                        .font(WhikFont.caption())
                                        .foregroundStyle(WhikColors.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(WhikColors.textTertiary)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 60)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                TextScanSheetStore.forget(s.id)
                                sheets = TextScanSheetStore.load()
                            } label: {
                                Label(L("Remove from this list"), systemImage: "minus.circle")
                            }
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WhikColors.surface))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(WhikColors.border, lineWidth: 1))
            }
            TextScanSecondaryButton(title: L("New sheet"), icon: "plus") { showNewSheet = true }
            TextScanSecondaryButton(title: L("Use an existing sheet link"), icon: "link") { showLink = true }
        }
    }

    /// Connected Google account, centered under the top bar as one pill.
    private var accountRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(WhikColors.textSecondary)
            Text(google.email?.isEmpty == false ? google.email! : L("Google account connected"))
                .font(WhikFont.subheadline())
                .foregroundStyle(WhikColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Rectangle()
                .fill(WhikColors.border)
                .frame(width: 1, height: 16)
                .accessibilityHidden(true)
            Button(L("Disconnect")) {
                google.disconnect()
                sheet = nil
                header = nil
                stage = .start
            }
            .font(WhikFont.subheadline().weight(.semibold))
            .foregroundStyle(WhikColors.mint)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 40)
        .background(Capsule().fill(WhikColors.surface))
        .overlay(Capsule().stroke(WhikColors.border, lineWidth: 1))
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    private var captureStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let sheet, let header { selectedSheetCard(sheet, header) }
            Text(L("Scan the paper"))
                .font(WhikFont.title(22))
                .foregroundStyle(WhikColors.textPrimary)
            Text(L("Lay the paper flat in good light. A form with two sides takes two scans."))
                .font(WhikFont.subheadline())
                .foregroundStyle(WhikColors.textSecondary)
            if !pages.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        ZStack(alignment: .topTrailing) {
                            Color.clear
                                .aspectRatio(3 / 4, contentMode: .fit)
                                .overlay(Image(uiImage: page).resizable().scaledToFill())
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            WhikCircleButton(systemImage: "xmark", size: 30, label: L("Remove")) {
                                pages.remove(at: index)
                            }
                            .padding(6)
                        }
                    }
                }
            }
            if pages.count < Self.maxPages {
                HStack(spacing: 10) {
                    TextScanSecondaryButton(title: L("Scan"), icon: "doc.viewfinder") {
                        if VNDocumentCameraViewController.isSupported { showCamera = true } else { error = L("This device can't scan documents. Choose photos instead.") }
                    }
                    PhotosPicker(selection: $photoItems, maxSelectionCount: Self.maxPages - pages.count, matching: .images) {
                        TextScanButtonLabel(title: L("Photos"), icon: "photo", prominent: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            TextScanPrimaryButton(title: L("Read the text"), icon: "text.viewfinder", disabled: pages.isEmpty) {
                run { try await read() }
            }
        }
    }

    private func selectedSheetCard(_ sheet: TextScanSheet, _ header: TextScanHeader) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "tablecells").foregroundStyle(WhikColors.mint)
                Text(sheet.title.isEmpty ? L("Untitled sheet") : sheet.title)
                    .font(WhikFont.body(.semibold))
                    .foregroundStyle(WhikColors.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button(L("Change")) {
                    pages = []
                    stage = .sheets
                }
                .font(WhikFont.subheadline())
                .foregroundStyle(WhikColors.mint)
            }
            TextScanColumnChips(names: header.names)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WhikColors.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(WhikColors.border, lineWidth: 1))
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Check before adding"))
                .font(WhikFont.title(22))
                .foregroundStyle(WhikColors.textPrimary)
            Text(L("Compare with the paper and fix anything that's wrong. Yellow boxes were hard to read."))
                .font(WhikFont.subheadline())
                .foregroundStyle(WhikColors.textSecondary)
            if let header {
                ForEach($rows) { $row in
                    TextScanRowCard(row: $row, columns: header.names, number: (rows.firstIndex { $0.id == row.id } ?? 0) + 1) {
                        rows.removeAll { $0.id == row.id }
                    }
                }
                TextScanSecondaryButton(title: L("Add a row"), icon: "plus") {
                    rows.append(TextScanEditableRow(values: Array(repeating: "", count: header.columns.count)))
                }
            }
            let filled = rows.filter { !$0.isEmpty }.count
            TextScanPrimaryButton(title: String(format: L("Add to the sheet (%d)"), filled), icon: "arrow.down.doc", disabled: filled == 0) {
                run { try await save() }
            }
            Button(L("Scan again")) {
                rows = []
                stage = .capture
            }
            .font(WhikFont.body(.medium))
            .foregroundStyle(WhikColors.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func savedStep(count: Int, firstRow: Int?) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(WhikColors.mint)
                .padding(.top, 40)
            Text(String(format: L("%d added to the sheet"), count))
                .font(WhikFont.title(24))
                .foregroundStyle(WhikColors.textPrimary)
            if let firstRow {
                Text(String(format: L("They start at row %d of the sheet."), firstRow))
                    .font(WhikFont.body())
                    .foregroundStyle(WhikColors.textSecondary)
            }
            if let sheet {
                Link(destination: sheet.url) {
                    TextScanButtonLabel(title: L("Open the sheet"), icon: "arrow.up.right.square", prominent: false)
                }
            }
            TextScanPrimaryButton(title: L("Scan the next one"), icon: "doc.viewfinder") {
                pages = []
                rows = []
                stage = .capture
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(.white).scaleEffect(1.2)
                Text(stage == .capture ? L("Reading the text…") : L("Just a moment…"))
                    .font(WhikFont.body(.medium))
                    .foregroundStyle(WhikColors.textPrimary)
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WhikColors.surfaceRaised))
        }
    }

    // MARK: - Actions

    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
            } catch TextScanGoogleAuth.AuthError.cancelled {
                // The user closed the Google page: nothing to report.
            } catch GoogleSheetsClient.SheetsError.notConnected {
                google.disconnect()
                stage = .start
                error = GoogleSheetsClient.SheetsError.notConnected.errorDescription
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func sheetsClient() async throws -> GoogleSheetsClient {
        GoogleSheetsClient(accessToken: try await google.accessTokenForSheets())
    }

    private func select(_ chosen: TextScanSheet) async throws {
        let client = try await sheetsClient()
        let fresh = try await client.sheet(id: chosen.id)
        let found = try await client.header(of: fresh)
        TextScanSheetStore.remember(fresh)
        sheets = TextScanSheetStore.load()
        sheet = fresh
        header = found
        pages = []
        stage = .capture
    }

    private func openLinkedSheet(_ link: String) async throws {
        guard let id = TextScanSheetMath.spreadsheetID(from: link) else {
            throw GoogleSheetsClient.SheetsError.notFound
        }
        try await select(TextScanSheet(id: id, title: "", tab: ""))
    }

    private func createSheet(title: String, columns: [String]) async throws {
        let created = try await sheetsClient().create(title: title, columns: columns)
        try await select(created)
    }

    private func read() async throws {
        guard let sheet, let header else { return }
        let jpegs = TextScanImage.jpegs(pages)
        let found = try await TextScanAPIClient().extract(jpegs: jpegs, columns: header.names, sheetTitle: sheet.title)
        guard !found.isEmpty else {
            error = L("Couldn't find writing that fits this sheet's columns. Scan the paper again, closer and in good light.")
            return
        }
        rows = found.map { found in
            TextScanEditableRow(
                values: found.values,
                uncertain: Set(found.uncertain),
                alternatives: Dictionary((found.alternatives ?? []).map { ($0.index, $0.value) }, uniquingKeysWith: { first, _ in first })
            )
        }
        stage = .review
    }

    private func save() async throws {
        guard let sheet, let header else { return }
        let toWrite = rows.filter { !$0.isEmpty }.map(\.values)
        let firstRow = try await sheetsClient().append(rows: toWrite, to: sheet, header: header)
        stage = .saved(count: toWrite.count, firstRow: firstRow)
    }
}

struct TextScanEditableRow: Identifiable, Equatable {
    let id = UUID()
    var values: [String]
    var uncertain: Set<Int> = []
    /// Column -> another reading of it, when the two readers disagreed.
    var alternatives: [Int: String] = [:]

    var isEmpty: Bool { values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

enum TextScanImage {
    /// All pages of one request stay under this (the server takes about 4 MB of base64 in total).
    static let requestBudgetBytes = 2_900_000
    /// Long edges tried from sharpest down: small, light handwriting loses strokes below ~2000 px.
    static let edges: [CGFloat] = [2400, 2000, 1600, 1200]

    /// The sharpest pages that fit the request budget together.
    static func jpegs(_ images: [UIImage]) -> [Data] {
        var smallest: [Data] = []
        for edge in edges {
            let encoded = images.compactMap { jpeg($0, maxEdge: edge) }
            smallest = encoded
            if encoded.reduce(0, { $0 + $1.count }) <= requestBudgetBytes { return encoded }
        }
        return smallest
    }

    static func jpeg(_ image: UIImage, maxEdge: CGFloat) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxEdge / max(longest, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.85)
    }
}

// MARK: - Pieces

private struct TextScanRowCard: View {
    @Binding var row: TextScanEditableRow
    let columns: [String]
    let number: Int
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(format: L("Row %d"), number))
                    .font(WhikFont.body(.semibold))
                    .foregroundStyle(WhikColors.textPrimary)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").foregroundStyle(WhikColors.danger)
                }
                .accessibilityLabel(L("Delete this row"))
            }
            ForEach(Array(columns.enumerated()), id: \.offset) { index, name in
                let unsure = row.uncertain.contains(index)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(WhikFont.caption())
                        .foregroundStyle(unsure ? Color.yellow : WhikColors.textTertiary)
                    TextField("", text: Binding(
                        get: { index < row.values.count ? row.values[index] : "" },
                        set: { newValue in
                            while row.values.count <= index { row.values.append("") }
                            row.values[index] = newValue
                            row.uncertain.remove(index)
                            row.alternatives[index] = nil
                        }
                    ))
                    .font(WhikFont.body())
                    .foregroundStyle(WhikColors.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WhikColors.surfaceRaised))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(unsure ? Color.yellow.opacity(0.85) : WhikColors.border, lineWidth: unsure ? 2 : 1)
                    )
                    if let other = row.alternatives[index] {
                        Button {
                            GonggiHaptics.light()
                            let current = index < row.values.count ? row.values[index] : ""
                            while row.values.count <= index { row.values.append("") }
                            row.values[index] = other
                            // Keep the swap reversible until the user types.
                            row.alternatives[index] = current.isEmpty ? nil : current
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.left.arrow.right")
                                Text(String(format: L("Other reading: %@"), other))
                                    .lineLimit(1)
                            }
                            .font(WhikFont.caption().weight(.semibold))
                            .foregroundStyle(Color.yellow)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.yellow.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(L("Uses this reading instead"))
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WhikColors.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(WhikColors.border, lineWidth: 1))
    }
}

private struct TextScanColumnChips: View {
    let names: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .font(WhikFont.caption())
                        .foregroundStyle(WhikColors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(WhikColors.surfaceRaised))
                }
            }
        }
    }
}

struct TextScanButtonLabel: View {
    let title: String
    let icon: String
    let prominent: Bool

    var body: some View {
        Label(title, systemImage: icon)
            .font(WhikFont.body(.semibold))
            .foregroundStyle(prominent ? WhikColors.onMint : WhikColors.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(prominent ? WhikColors.mint : WhikColors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(prominent ? Color.clear : WhikColors.border, lineWidth: 1)
            )
    }
}

private struct TextScanPrimaryButton: View {
    let title: String
    let icon: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button {
            GonggiHaptics.medium()
            action()
        } label: {
            TextScanButtonLabel(title: title, icon: icon, prominent: true)
        }
        .buttonStyle(GonggiPressableStyle(scale: 0.98))
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

private struct TextScanSecondaryButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button {
            GonggiHaptics.light()
            action()
        } label: {
            TextScanButtonLabel(title: title, icon: icon, prominent: false)
        }
        .buttonStyle(GonggiPressableStyle(scale: 0.98))
    }
}

/// New sheet: a name and its column names (the first row).
private struct TextScanNewSheetForm: View {
    let onCreate: (String, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var columns: [String] = ["", "", ""]

    private var cleanColumns: [String] {
        columns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Sheet name")) {
                    TextField(L("e.g. Inventory"), text: $title)
                }
                Section {
                    ForEach(columns.indices, id: \.self) { i in
                        TextField(String(format: L("Column %d"), i + 1), text: $columns[i])
                    }
                    .onDelete { columns.remove(atOffsets: $0) }
                    if columns.count < 26 {
                        Button(L("Add a column")) { columns.append("") }
                    }
                } header: {
                    Text(L("Column names"))
                } footer: {
                    Text(L("For example: Item, Quantity, Unit. They become the first row of the sheet."))
                }
            }
            .navigationTitle(L("New sheet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Create")) {
                        onCreate(title.trimmingCharacters(in: .whitespacesAndNewlines), cleanColumns)
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cleanColumns.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Existing sheet: paste its link (the Google account must be able to edit it).
private struct TextScanLinkForm: View {
    let onUse: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://docs.google.com/spreadsheets/d/…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button(L("Paste")) { link = UIPasteboard.general.string ?? link }
                } header: {
                    Text(L("Sheet link"))
                } footer: {
                    Text(L("In Google Sheets, tap Share and copy the link. The connected Google account needs edit access, and the first row needs column names."))
                }
            }
            .navigationTitle(L("Existing sheet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Use")) { onUse(link) }
                        .disabled(TextScanSheetMath.spreadsheetID(from: link) == nil)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// VisionKit document camera: finds the paper edges and flattens each page.
private struct TextScanDocumentCamera: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        init(onFinish: @escaping ([UIImage]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish([])
        }
    }
}
