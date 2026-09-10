import AVFoundation
import AuthenticationServices
import CoreLocation
import SwiftUI
import UIKit

// MARK: - Profile edit name

struct ProfileEditNameView: View {
    @ObservedObject private var auth = AuthSessionController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var saving = false
    @State private var errorMessage: String?
    private let maxLength = 80

    var body: some View {
        Form {
            Section {
                TextField("표시 이름", text: $name)
                    .textInputAutocapitalization(.words)
                    .disabled(saving)
                Text("\(name.trimmingCharacters(in: .whitespacesAndNewlines).count)/\(maxLength)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(GonggiColors.error) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle("프로필 수정")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("저장") { Task { await save() } }
                    .disabled(saving || !canSave)
            }
        }
        .onAppear {
            name = auth.profile?.name ?? auth.currentUser?.displayName ?? ""
        }
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxLength && !saving
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            try await auth.updateDisplayName(name)
            dismiss()
        } catch let MobileAuthAPIError.server(_, message, _) {
            errorMessage = message
        } catch {
            errorMessage = "이름을 저장하지 못했어요."
        }
    }
}

// MARK: - Email (read-only)

struct ProfileEmailView: View {
    @ObservedObject private var auth = AuthSessionController.shared

    private var provider: String {
        (auth.profile?.provider ?? auth.currentUser?.provider ?? "").uppercased()
    }

    var body: some View {
        List {
            Section("계정 정보") {
                LabeledContent("이메일", value: auth.profile?.email ?? auth.currentUser?.email ?? "—")
                LabeledContent(
                    "인증",
                    value: (auth.profile?.emailVerified == true) ? "인증됨" : "미인증"
                )
                LabeledContent("가입 / 주 로그인", value: Self.label(provider))
            }
            if provider == "GOOGLE" {
                Section {
                    Text("이 이메일은 Google 계정에서 관리됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if provider == "APPLE" {
                Section {
                    Text("이 이메일은 Apple 계정에서 관리됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle("이메일")
    }

    private static func label(_ p: String) -> String {
        switch p {
        case "GOOGLE": return "Google"
        case "APPLE": return "Apple"
        case "LOCAL": return "이메일"
        default: return p.isEmpty ? "—" : p
        }
    }
}

// MARK: - Providers (status only)

struct ProfileProvidersView: View {
    @ObservedObject private var auth = AuthSessionController.shared

    private var rows: [String] {
        if let ids = auth.profile?.providers, !ids.isEmpty { return ids }
        if let p = auth.profile?.provider, !p.isEmpty { return [p] }
        return []
    }

    var body: some View {
        List {
            Section {
                if rows.isEmpty {
                    Text("로그인 방법을 확인할 수 없습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows, id: \.self) { id in
                        Text("\(Self.label(id)) 연결됨")
                    }
                }
            } footer: {
                Text("연결 추가·해제는 아직 지원하지 않습니다.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle("로그인 방법")
        .task { await auth.refreshProfile() }
    }

    private static func label(_ p: String) -> String {
        switch p.uppercased() {
        case "GOOGLE": return "Google"
        case "APPLE": return "Apple"
        case "LOCAL": return "이메일"
        default: return p
        }
    }
}

// MARK: - Password

struct ProfilePasswordView: View {
    enum Mode { case change, set }

    let mode: Mode
    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var saving = false
    @State private var message: String?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if mode == .change {
                Section("현재 비밀번호") {
                    SecureField("현재 비밀번호", text: $current)
                        .textContentType(.password)
                }
            }
            Section("새 비밀번호") {
                SecureField("새 비밀번호 (8자 이상)", text: $newPassword)
                    .textContentType(.newPassword)
                SecureField("새 비밀번호 확인", text: $confirm)
                    .textContentType(.newPassword)
            }
            if let message {
                Section { Text(message).foregroundStyle(GonggiColors.accentTeal) }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(GonggiColors.error) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle(mode == .change ? "비밀번호 변경" : "비밀번호 설정")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("저장") { Task { await save() } }
                    .disabled(saving || !canSave)
            }
        }
    }

    private var canSave: Bool {
        guard newPassword.count >= 8, newPassword == confirm, !saving else { return false }
        if mode == .change { return !current.isEmpty }
        return true
    }

    private func save() async {
        guard canSave, let token = AuthSessionController.shared.accessToken else { return }
        saving = true
        errorMessage = nil
        message = nil
        defer { saving = false }
        do {
            let api = MobileAccountAPIClient()
            try await api.changePassword(
                accessToken: token,
                currentPassword: mode == .change ? current : nil,
                newPassword: newPassword
            )
            message = "비밀번호가 변경되었습니다."
            current = ""
            newPassword = ""
            confirm = ""
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        } catch let MobileAuthAPIError.server(_, msg, _) {
            errorMessage = msg
        } catch {
            errorMessage = "비밀번호를 변경하지 못했어요."
        }
    }
}

// MARK: - Plan

struct ProfilePlanView: View {
    @ObservedObject private var auth = AuthSessionController.shared

    var body: some View {
        List {
            Section {
                LabeledContent("현재 플랜", value: auth.profile?.planLabel ?? "—")
                if let end = auth.profile?.planPeriodEnd, let formatted = Self.formatISO(end) {
                    LabeledContent("갱신 / 만료", value: formatted)
                }
            }
            Section("주요 한도") {
                Text(Self.limitsCopy(for: auth.profile?.planCode))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle("현재 플랜")
        .task { await auth.refreshProfile() }
    }

    private static func limitsCopy(for code: String?) -> String {
        switch (code ?? "").uppercased() {
        case "STANDARD":
            return "월 3D 생성 한도 8회, 포함 크레딧 120"
        case "PRO":
            return "월 3D 생성 한도 23회, 포함 크레딧 300"
        case "FREE":
            return "크레딧 기반 이용 (월 생성 횟수 한도 없음)"
        default:
            return "서버에 등록된 플랜 한도가 적용됩니다."
        }
    }

    private static func formatISO(_ iso: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "ko_KR")
        out.dateStyle = .medium
        return out.string(from: date)
    }
}

// MARK: - Credits

struct ProfileCreditsView: View {
    @State private var credits: MobileAccountCreditsDTO?
    @State private var errorMessage: String?
    @State private var loading = true

    var body: some View {
        List {
            Section("잔액") {
                if loading {
                    ProgressView()
                } else if let credits {
                    Text("\(credits.balance)")
                        .font(.title2.weight(.semibold))
                } else {
                    Text(errorMessage ?? "잔액을 불러오지 못했어요.")
                        .foregroundStyle(.secondary)
                }
            }
            if let entries = credits?.entries, !entries.isEmpty {
                Section("최근 내역") {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.kind)
                                Spacer()
                                Text(entry.delta >= 0 ? "+\(entry.delta)" : "\(entry.delta)")
                                    .foregroundStyle(entry.delta >= 0 ? GonggiColors.accentTeal : GonggiColors.error)
                            }
                            Text(Self.formatISO(entry.createdAt) ?? entry.createdAt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle("크레딧")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let token = AuthSessionController.shared.accessToken else {
            errorMessage = "로그인이 필요합니다."
            return
        }
        do {
            credits = try await MobileAccountAPIClient().fetchCredits(accessToken: token)
            errorMessage = nil
        } catch let MobileAuthAPIError.server(_, message, _) {
            errorMessage = message
            credits = nil
        } catch {
            errorMessage = "크레딧을 불러오지 못했어요."
            credits = nil
        }
    }

    private static func formatISO(_ iso: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "ko_KR")
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }
}

// MARK: - Usage

struct ProfileUsageView: View {
    @State private var usage: MobileAccountUsageDTO?
    @State private var errorMessage: String?
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if let usage {
                Section {
                    LabeledContent("공간", value: "\(usage.spaces)")
                    LabeledContent("생성 중", value: "\(usage.generatingSpaces)")
                    LabeledContent("공유 중", value: "\(usage.sharedSpaces)")
                    LabeledContent("3D 자산", value: "\(usage.assets3d)")
                    if let bytes = usage.storageBytes {
                        LabeledContent("저장 용량", value: Self.formatBytes(bytes))
                    }
                }
            } else {
                Text(errorMessage ?? "사용량을 불러오지 못했어요.")
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle("콘텐츠 사용량")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let token = AuthSessionController.shared.accessToken else {
            errorMessage = "로그인이 필요합니다."
            return
        }
        do {
            usage = try await MobileAccountAPIClient().fetchUsage(accessToken: token)
        } catch let MobileAuthAPIError.server(_, message, _) {
            errorMessage = message
        } catch {
            errorMessage = "사용량을 불러오지 못했어요."
        }
    }

    private static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Shared spaces

struct ProfileSharedSpacesView: View {
    @State private var spaces: [MobileSharedSpaceDTO] = []
    @State private var errorMessage: String?
    @State private var loading = true
    @State private var shareItem: SharePayload?
    @State private var revokingId: String?

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if spaces.isEmpty {
                Text(errorMessage ?? "공유 중인 공간이 없습니다.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(spaces) { space in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(space.title).font(.headline)
                        if let date = Self.formatISO(space.sharedAt) {
                            Text("공유 시작 \(date)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("링크 복사") {
                                UIPasteboard.general.string = space.shareUrl
                                GonggiHaptics.light()
                            }
                            Button("공유") {
                                shareItem = SharePayload(url: space.shareUrl)
                            }
                            Spacer()
                            Button("공유 해제", role: .destructive) {
                                Task { await revoke(space) }
                            }
                            .disabled(revokingId == space.spaceId)
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle("공유 관리")
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.url])
        }
        .onReceive(NotificationCenter.default.publisher(for: .gonggiAccountPresentationDidReset)) { _ in
            spaces = []
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let token = AuthSessionController.shared.accessToken else {
            spaces = []
            errorMessage = "로그인이 필요합니다."
            return
        }
        do {
            spaces = try await MobileAccountAPIClient().fetchSharedSpaces(accessToken: token)
            errorMessage = nil
        } catch let MobileAuthAPIError.server(_, message, _) {
            errorMessage = message
            spaces = []
        } catch {
            errorMessage = "공유 목록을 불러오지 못했어요."
            spaces = []
        }
    }

    private func revoke(_ space: MobileSharedSpaceDTO) async {
        guard let token = AuthSessionController.shared.accessToken else { return }
        revokingId = space.spaceId
        defer { revokingId = nil }
        do {
            _ = try await MobileAuthAPIClient().setSpaceShare(
                accessToken: token,
                spaceId: space.spaceId,
                enabled: false
            )
            spaces.removeAll { $0.spaceId == space.spaceId }
        } catch {
            errorMessage = "공유를 해제하지 못했어요."
        }
    }

    private static func formatISO(_ iso: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "ko_KR")
        out.dateStyle = .medium
        return out.string(from: date)
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let url: String
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - App settings

struct ProfileAppSettingsView: View {
    let userId: String?
    @State private var captureLocationEnabled: Bool
    @State private var allowCellular: Bool = GonggiAppSettings.allowCellularUpload
    @State private var hapticsEnabled: Bool = GonggiAppSettings.hapticsEnabled

    init(userId: String?) {
        self.userId = userId
        _captureLocationEnabled = State(
            initialValue: SpaceCaptureLocationPreferences.isEnabled(userId: userId)
        )
    }

    var body: some View {
        List {
            Toggle("셀룰러 데이터로 업로드 허용", isOn: $allowCellular)
                .onChange(of: allowCellular) { _, value in
                    GonggiAppSettings.allowCellularUpload = value
                }
            Toggle("촬영 위치 저장", isOn: $captureLocationEnabled)
                .onChange(of: captureLocationEnabled) { _, enabled in
                    SpaceCaptureLocationPreferences.setEnabled(enabled, userId: userId)
                    if enabled {
                        Task { _ = try? await SpaceOneShotLocation().request() }
                    }
                }
                .disabled(userId == nil)
            Toggle("햅틱 피드백", isOn: $hapticsEnabled)
                .onChange(of: hapticsEnabled) { _, value in
                    GonggiAppSettings.hapticsEnabled = value
                }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle("앱 설정")
    }
}

// MARK: - Privacy / permissions

struct ProfilePrivacyPermissionsView: View {
    @ObservedObject private var auth = AuthSessionController.shared
    @State private var camera = "확인 중"
    @State private var location = "확인 중"
    @State private var mic = "확인 중"
    @State private var safariURL: SpaceLinkIdentifiedURL?

    var body: some View {
        List {
            Section("권한") {
                permissionRow("카메라", status: camera)
                permissionRow("위치", status: location)
                permissionRow("마이크", status: mic)
                Button("iOS 설정 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Section("약관") {
                Button("개인정보처리방침") {
                    safariURL = SpaceLinkIdentifiedURL(url: GonggiProductURLs.privacyPolicy)
                }
                Button("이용약관") {
                    safariURL = SpaceLinkIdentifiedURL(url: GonggiProductURLs.termsOfService)
                }
            }
            Section {
                NavigationLink("공유 중인 공간 관리") {
                    ProfileSharedSpacesView()
                }
                NavigationLink("차단한 사용자") {
                    BlockedPublishersView(
                        userId: auth.profile?.id ?? auth.currentUser?.userId
                    )
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle("권한 및 개인정보")
        .task { refreshStatuses() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshStatuses()
        }
        .sheet(item: $safariURL) { item in
            SpaceLinkSafariView(url: item.url) { safariURL = nil }
        }
    }

    private func permissionRow(_ title: String, status: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(status).foregroundStyle(.secondary)
        }
    }

    private func refreshStatuses() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = "허용됨"
        case .denied: camera = "허용 안 됨"
        case .restricted: camera = "제한됨"
        case .notDetermined: camera = "아직 요청하지 않음"
        @unknown default: camera = "—"
        }

        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: location = "허용됨"
        case .denied: location = "허용 안 됨"
        case .restricted: location = "제한됨"
        case .notDetermined: location = "아직 요청하지 않음"
        @unknown default: location = "—"
        }

        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: mic = "허용됨"
        case .denied: mic = "허용 안 됨"
        case .undetermined: mic = "아직 요청하지 않음"
        @unknown default: mic = "—"
        }
    }
}

// MARK: - Help

struct ProfileHelpView: View {
    @State private var safariURL: SpaceLinkIdentifiedURL?
    @State private var copied = false

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "—"
        let b = info?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        List {
            Section("안내") {
                helpLink("공간 촬영 방법")
                helpLink("공간 생성 상태 설명")
                helpLink("공유 방법")
                helpLink("핫스팟과 공간 연결 방법")
                helpLink("3D 자산과 AR 사용 방법")
            }
            Section("문의") {
                Button("문의하기") {
                    safariURL = SpaceLinkIdentifiedURL(url: GonggiProductURLs.support)
                }
            }
            Section("앱 정보") {
                LabeledContent("버전", value: versionLine)
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle("도움말 및 문의")
        .sheet(item: $safariURL) { item in
            SpaceLinkSafariView(url: item.url) { safariURL = nil }
        }
    }

    private func helpLink(_ title: String) -> some View {
        Button(title) {
            safariURL = SpaceLinkIdentifiedURL(url: GonggiProductURLs.helpCapture)
        }
    }
}

// MARK: - Delete account

struct ProfileDeleteAccountView: View {
    @ObservedObject private var auth = AuthSessionController.shared
    @State private var confirmed = false
    @State private var password = ""
    @State private var busy = false
    @State private var errorMessage: String?
    private let appleCoordinator = DeleteAppleReauthCoordinator()

    private var provider: String {
        (auth.profile?.provider ?? "").uppercased()
    }

    var body: some View {
        List {
            Section {
                Text("공기와 3D Locker 계정이 함께 삭제됩니다. 저장한 공간과 3D 자산, 공유 링크와 남은 크레딧을 더 이상 이용할 수 없습니다.")
                    .font(.footnote)
            }
            Section("삭제 대상") {
                Text("통합 사용자 계정, 공기 공간, 원본 촬영, 파노라마, 오디오, 핫스팟 연결, 공유 링크, 3D Locker 자산, 세션과 인증 토큰")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("보관") {
                Text("법적으로 보관해야 하는 결제와 회계 기록은 계정 데이터와 분리되어 보관 정책에 따라 유지됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if provider == "LOCAL" || auth.profile?.hasPassword == true {
                Section("비밀번호 확인") {
                    SecureField("현재 비밀번호", text: $password)
                }
            }
            Section {
                Toggle("위 내용을 확인했으며 계정을 삭제합니다.", isOn: $confirmed)
                Button("회원 탈퇴", role: .destructive) {
                    Task { await delete() }
                }
                .disabled(!confirmed || busy)
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(GonggiColors.error) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle("회원 탈퇴")
        .disabled(busy)
    }

    private func delete() async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            switch provider {
            case "APPLE":
                let tokens = try await appleCoordinator.reauthenticate()
                try await auth.deleteAccount(
                    appleIdentityToken: tokens.identityToken,
                    appleAuthorizationCode: tokens.authorizationCode
                )
            case "GOOGLE":
                let idToken = try await GoogleSignInCoordinator.shared.signIn()
                try await auth.deleteAccount(googleIdToken: idToken)
            default:
                try await auth.deleteAccount(currentPassword: password)
            }
        } catch let MobileAuthAPIError.server(_, message, _) {
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription.isEmpty
                ? "계정 삭제를 완료하지 못했어요."
                : error.localizedDescription
        }
    }
}

@MainActor
final class DeleteAppleReauthCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<(identityToken: String, authorizationCode: String?), Error>?

    func reauthenticate() async throws -> (identityToken: String, authorizationCode: String?) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.email]
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8)
        else {
            continuation?.resume(throwing: MobileAuthAPIError.server(
                code: "REAUTH_FAILED",
                message: "Apple 계정 확인에 실패했습니다.",
                status: 401
            ))
            continuation = nil
            return
        }
        let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        continuation?.resume(returning: (token, code))
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
