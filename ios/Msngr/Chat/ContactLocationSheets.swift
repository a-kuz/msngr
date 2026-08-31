import SwiftUI
import MapKit
import Contacts
import ContactsUI
import MsngrCore

/// The system contact picker; picking hands over a card built from what the
/// contact holds, never a reference into the address book.
struct ContactPickerSheet: UIViewControllerRepresentable {
    var onPick: (ContactCard) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (ContactCard) -> Void
        init(onPick: @escaping (ContactCard) -> Void) { self.onPick = onPick }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let name = CNContactFormatter.string(from: contact, style: .fullName)
                ?? contact.givenName
            onPick(ContactCard(
                name: name.isEmpty ? String(localized: "Contact") : name,
                phones: contact.phoneNumbers.map { $0.value.stringValue },
                emails: contact.emailAddresses.map { String($0.value) }))
        }
    }
}

/// Picking a point: the map under a fixed center pin; sending takes whatever
/// the crosshair stands on. The map starts at the device's location when the
/// system grants it, and at the last chosen region otherwise.
struct LocationPickerSheet: View {
    var onPick: (LocationInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 59.9343, longitude: 30.3351),
            latitudinalMeters: 1200, longitudinalMeters: 1200)))
    @State private var center = CLLocationCoordinate2D(latitude: 59.9343, longitude: 30.3351)
    private let locationAsk = CLLocationManager()

    var body: some View {
        NavigationStack {
            Map(position: $position)
                .onMapCameraChange { context in center = context.region.center }
                .overlay {
                    Image(systemName: "mappin")
                        .font(.system(size: 34))
                        .foregroundStyle(.red)
                        .shadow(radius: 2)
                        .offset(y: -14)
                        .allowsHitTesting(false)
                }
                .mapControls { MapUserLocationButton() }
                .onAppear {
                    if locationAsk.authorizationStatus == .notDetermined {
                        locationAsk.requestWhenInUseAuthorization()
                    }
                }
                .navigationTitle(Text("Location"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Send")) {
                            onPick(LocationInfo(lat: center.latitude, lon: center.longitude))
                            dismiss()
                        }
                        .accessibilityIdentifier("location.send")
                    }
                }
        }
    }
}

/// The received card: the person, their phones and emails, and a way to keep
/// them — copy a row, or save the whole card into Contacts.
struct ContactViewerSheet: View {
    let card: ContactCard
    @State private var saved = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(card.phones, id: \.self) { phone in
                        Button { UIPasteboard.general.string = phone } label: {
                            Label(phone, systemImage: "phone")
                        }
                    }
                    ForEach(card.emails, id: \.self) { email in
                        Button { UIPasteboard.general.string = email } label: {
                            Label(email, systemImage: "envelope")
                        }
                    }
                } footer: {
                    if !card.phones.isEmpty || !card.emails.isEmpty {
                        Text("A tap copies the row.")
                    }
                }
                Section {
                    Button {
                        saveToContacts()
                    } label: {
                        Label(saved ? String(localized: "Saved") : String(localized: "Save to Contacts"),
                              systemImage: saved ? "checkmark" : "person.crop.circle.badge.plus")
                    }
                    .disabled(saved)
                    .accessibilityIdentifier("contact.save")
                }
            }
            .navigationTitle(card.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func saveToContacts() {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { granted, _ in
            guard granted else { return }
            let new = CNMutableContact()
            let parts = card.name.split(separator: " ", maxSplits: 1).map(String.init)
            new.givenName = parts.first ?? card.name
            if parts.count > 1 { new.familyName = parts[1] }
            new.phoneNumbers = card.phones.map {
                CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0))
            }
            new.emailAddresses = card.emails.map {
                CNLabeledValue(label: CNLabelHome, value: $0 as NSString)
            }
            let request = CNSaveRequest()
            request.add(new, toContainerWithIdentifier: nil)
            try? store.execute(request)
            Task { @MainActor in saved = true }
        }
    }
}

/// The received point full screen, with a road out into the system map.
struct LocationViewerSheet: View {
    let point: LocationInfo
    @Environment(\.dismiss) private var dismiss

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
    }

    var body: some View {
        NavigationStack {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: coordinate, latitudinalMeters: 900, longitudinalMeters: 900))) {
                Marker(point.name ?? String(localized: "Location"), coordinate: coordinate)
            }
            .navigationTitle(point.name ?? String(localized: "Location"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Open in Maps")) {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
                        item.name = point.name
                        item.openInMaps()
                    }
                }
            }
        }
    }
}
