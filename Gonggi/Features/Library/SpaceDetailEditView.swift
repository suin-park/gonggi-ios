import SwiftUI

struct SpaceDetailEditView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let space: SpaceRecord

    @State private var name: String
    @State private var memo: String
    @State private var locationMode: LocationMode
    @State private var manualLocationName: String
    @State private var currentLocation: SpaceOneShotLocationResult?
    @State private var isLocating = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private enum LocationMode: Equatable {
        case existing
        case current
        case manual
        case removed
    }

    init(space: SpaceRecord) {
        self.space = space
        _name = State(initialValue: space.name)
        _memo = State(initialValue: space.memo ?? "")
        _locationMode = State(initialValue: .existing)
        _manualLocationName = State(initialValue: space.locationName ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("이름") {
                    TextField("공간 이름", text: $name)
                        .onChange(of: name) { _, value in
                            if value.count > 60 { name = String(value.prefix(60)) }
                        }
                    Text("\(name.count)/60")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("위치") {
                    Text(locationLabel)
                        .foregroundStyle(.secondary)

                    Button("현재 위치 사용") {
                        Task { await useCurrentLocation() }
                    }
                    .disabled(isLocating)

                    Button("직접 입력") {
                        locationMode = .manual
                    }

                    if locationMode == .manual {
                        TextField("위치 이름", text: $manualLocationName)
                            .onChange(of: manualLocationName) { _, value in
                                if value.count > 100 {
                                    manualLocationName = String(value.prefix(100))
                                }
                            }
                        Text("\(manualLocationName.count)/100")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("위치 제거", role: .destructive) {
                        locationMode = .removed
                    }
                }

                Section("메모") {
                    TextEditor(text: $memo)
                        .frame(minHeight: 140)
                        .onChange(of: memo) { _, value in
                            if value.count > 1_000 { memo = String(value.prefix(1_000)) }
                        }
                    Text("\(memo.count)/1000")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("공간 정보 편집")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isSaving)
            .overlay {
                if isSaving {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        ProgressView()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        Task { await save() }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("저장하지 못했어요", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var locationLabel: String {
        switch locationMode {
        case .existing:
            return space.locationDisplayLabel
        case .current:
            return "현재 위치"
        case .manual:
            let trimmed = manualLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "위치 이름을 입력해주세요." : trimmed
        case .removed:
            return "위치 정보 없음"
        }
    }

    @MainActor
    private func useCurrentLocation() async {
        isLocating = true
        defer { isLocating = false }
        do {
            currentLocation = try await SpaceOneShotLocation().request()
            locationMode = .current
        } catch {
            errorMessage = "현재 위치를 확인하지 못했어요. 위치 권한과 네트워크 상태를 확인해주세요."
        }
    }

    @MainActor
    private func save() async {
        do {
            let validName = try SpaceDetailMetadataValidator.title(name)
            let validMemo = try SpaceDetailMetadataValidator.memo(memo)

            var locationName: String?
            var latitude: Double?
            var longitude: Double?
            var source: String?
            var capturedAt: Date?
            let clearLocation = locationMode == .removed

            switch locationMode {
            case .existing:
                locationName = space.locationName
                latitude = space.latitude
                longitude = space.longitude
                source = space.locationSource
                capturedAt = space.locationCapturedAt
            case .current:
                guard let currentLocation else {
                    throw SpaceOneShotLocationError.unavailable
                }
                locationName = "현재 위치"
                latitude = currentLocation.latitude
                longitude = currentLocation.longitude
                source = "AUTO"
                capturedAt = currentLocation.capturedAt
            case .manual:
                let validLocation = try SpaceDetailMetadataValidator.locationName(manualLocationName)
                locationName = validLocation
                source = "MANUAL"
                capturedAt = Date()
            case .removed:
                break
            }

            isSaving = true
            defer { isSaving = false }
            try await appState.updateSpaceMetadata(
                jobId: space.id,
                title: validName,
                memo: validMemo,
                locationName: locationName,
                latitude: latitude,
                longitude: longitude,
                locationSource: source,
                locationCapturedAt: capturedAt,
                clearLocation: clearLocation
            )
            dismiss()
        } catch let error as SpaceMetadataUpdateError {
            errorMessage = error.userMessage
        } catch let error as SpaceDetailMetadataValidationError {
            switch error {
            case .emptyName: errorMessage = "공간 이름을 입력해주세요."
            case .nameTooLong: errorMessage = "공간 이름은 60자 이하여야 해요."
            case .memoTooLong: errorMessage = "메모는 1000자 이하여야 해요."
            case .emptyLocationName: errorMessage = "위치 이름을 입력해주세요."
            case .locationNameTooLong: errorMessage = "위치 이름은 100자 이하여야 해요."
            }
        } catch {
            errorMessage = "입력한 정보를 확인해주세요."
        }
    }
}
