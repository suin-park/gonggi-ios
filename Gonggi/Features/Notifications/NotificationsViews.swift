import SwiftUI

enum GonggiNotificationDate {
    static func relative(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: iso)
        }
        guard let date else { return iso }
        let rel = RelativeDateTimeFormatter()
        rel.locale = AppLanguage.shared.locale
        rel.unitsStyle = .short
        return rel.localizedString(for: date, relativeTo: Date())
    }
}

struct NotificationsListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var items: [GonggiNotificationItem] = []
    @State private var unreadCount = 0
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorText: String?
    @State private var selected: GonggiNotificationItem?

    private let api = MobileNotificationsAPIClient()

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView(L("Loading notifications…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText, items.isEmpty {
                ContentUnavailableView(
                    L("Couldn't load notifications"),
                    systemImage: "bell.slash",
                    description: Text(errorText)
                )
            } else if items.isEmpty {
                ContentUnavailableView(
                    L("No notifications"),
                    systemImage: "bell",
                    description: Text(L("Likes and comments from others will appear here."))
                )
            } else {
                List {
                    ForEach(items) { item in
                        Button {
                            selected = item
                        } label: {
                            notificationRow(item)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if item.id == items.last?.id {
                                Task { await loadMore() }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(GonggiAmbientBackground())
        .navigationTitle(L("Notifications"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L("Mark all as read")) {
                    Task { await markAllRead() }
                }
                .disabled(unreadCount == 0 || isLoading)
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
        .navigationDestination(item: $selected) { item in
            NotificationDetailView(notificationId: item.id, preview: item)
                .environmentObject(appState)
                .onDisappear {
                    Task { await softRefreshCounts(markReadId: item.id) }
                }
        }
    }

    private func notificationRow(_ item: GonggiNotificationItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(item.read ? Color.secondary : Color.accentColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.title)
                        .font(.subheadline.weight(item.read ? .regular : .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(item.typeLabelKo)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if let message = item.message, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !item.createdAt.isEmpty {
                    Text(GonggiNotificationDate.relative(item.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !item.read {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func reload() async {
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorText = L("Please sign in.")
            items = []
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let result = try await api.fetchList(accessToken: token, limit: 30)
            items = result.items
            unreadCount = result.unreadCount
            nextCursor = result.nextCursor
            await MainActor.run { appState.notificationUnreadCount = result.unreadCount }
        } catch {
            errorText = L("Please try again in a moment.")
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, let cursor = nextCursor, !cursor.isEmpty,
              let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty
        else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await api.fetchList(accessToken: token, limit: 30, cursor: cursor)
            let existing = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            nextCursor = result.nextCursor
            unreadCount = result.unreadCount
        } catch {}
    }

    private func markAllRead() async {
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else { return }
        do {
            try await api.markAllRead(accessToken: token)
            items = items.map {
                var copy = $0
                copy.read = true
                return copy
            }
            unreadCount = 0
            await MainActor.run { appState.notificationUnreadCount = 0 }
        } catch {}
    }

    private func softRefreshCounts(markReadId: String) async {
        items = items.map { item in
            guard item.id == markReadId else { return item }
            var copy = item
            copy.read = true
            return copy
        }
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else { return }
        if let count = try? await api.fetchUnreadCount(accessToken: token) {
            unreadCount = count
            await MainActor.run { appState.notificationUnreadCount = count }
        }
    }
}

struct NotificationDetailView: View {
    let notificationId: String
    let preview: GonggiNotificationItem?

    @EnvironmentObject private var appState: AppState
    @State private var item: GonggiNotificationItem?
    @State private var isLoading = false
    @State private var errorText: String?

    private let api = MobileNotificationsAPIClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading && item == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let errorText, item == nil {
                    Text(errorText)
                        .foregroundStyle(.secondary)
                        .padding()
                } else if let item {
                    Label(item.typeLabelKo, systemImage: item.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(item.title)
                        .font(.title3.weight(.bold))

                    if let message = item.message, !message.isEmpty {
                        Text(message)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !item.createdAt.isEmpty {
                        Text(GonggiNotificationDate.relative(item.createdAt))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(GonggiSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GonggiAmbientBackground())
        .navigationTitle(L("Notification details"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            item = preview
            await load()
        }
    }

    private func load() async {
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            errorText = L("Please sign in.")
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let wasUnread = !(preview?.read ?? true)
            let detail = try await api.fetchDetail(accessToken: token, id: notificationId)
            item = detail
            if wasUnread {
                await MainActor.run {
                    appState.notificationUnreadCount = max(0, appState.notificationUnreadCount - 1)
                }
            }
        } catch {
            if item == nil {
                errorText = L("Can't open the notification.")
            }
        }
    }
}
