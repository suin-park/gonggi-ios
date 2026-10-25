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
                Section(L("Name")) {
                    TextField(L("Space name"), text: $name)
                        .onChange(of: name) { _, value in
                            if value.count > 60 { name = String(value.prefix(60)) }
                        }
                    Text("\(name.count)/60")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L("Location")) {
                    Text(locationLabel)
                        .foregroundStyle(.secondary)

                    Button(L("Use current location")) {
                        Task { await useCurrentLocation() }
                    }
                    .disabled(isLocating)

                    Button(L("Enter manually")) {
                        locationMode = .manual
                    }

                    if locationMode == .manual {
                        TextField(L("Location name"), text: $manualLocationName)
                            .onChange(of: manualLocationName) { _, value in
                                if value.count > 100 {
                                    manualLocationName = String(value.prefix(100))
                                }
                            }
                        Text("\(manualLocationName.count)/100")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button(L("Remove location"), role: .destructive) {
                        locationMode = .removed
                    }
                }

                Section(L("Notes")) {
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
            .navigationTitle(L("Edit space details"))
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
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) {
                        Task { await save() }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert(L("Couldn't save"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(L("OK"), role: .cancel) {}
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
            return L("Current location")
        case .manual:
            let trimmed = manualLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L("Enter a location name.") : trimmed
        case .removed:
            return L("No location")
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
            errorMessage = L("Couldn't get your current location. Check location access and your network.")
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
                locationName = L("Current location")
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
            case .emptyName: errorMessage = L("Enter a space name.")
            case .nameTooLong: errorMessage = L("Space names can be up to 60 characters.")
            case .memoTooLong: errorMessage = L("Notes can be up to 1000 characters.")
            case .emptyLocationName: errorMessage = L("Enter a location name.")
            case .locationNameTooLong: errorMessage = L("Location names can be up to 100 characters.")
            }
        } catch {
            errorMessage = L("Check the information you entered.")
        }
    }
}
