import SwiftUI

/// Lists profiles, like Anki desktop's Switch Profile window.
struct ProfilesSection: View {
    @Environment(AppModel.self) private var app
    @State private var showAdd = false
    @State private var newName = ""
    @State private var renaming: Profile?
    @State private var renameText = ""
    @State private var deleting: Profile?

    var body: some View {
        Section {
            ForEach(app.profiles) { profile in
                Button {
                    app.switchProfile(to: profile.id)
                } label: {
                    HStack(spacing: 12) {
                        ProfileBadge(name: profile.name)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).foregroundStyle(Color.primary)
                            Text(account(profile))
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                        Spacer()
                        if profile.id == app.profile.id {
                            Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    if profile.id != app.profile.id {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = profile }
                    }
                    Button("Rename", systemImage: "pencil") {
                        renameText = profile.name
                        renaming = profile
                    }
                    .tint(.gray)
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") {
                        renameText = profile.name
                        renaming = profile
                    }
                    if profile.id != app.profile.id {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = profile }
                    }
                }
            }
            Button("Add Profile", systemImage: "person.crop.circle.badge.plus") {
                newName = ""
                showAdd = true
            }
        } header: {
            Text("Profiles")
        } footer: {
            Text("Each profile has its own decks, media and AnkiWeb account. Swipe a profile to rename or delete it.")
        }
        .alert("New Profile", isPresented: $showAdd) {
            TextField("Name", text: $newName)
            Button("Create") {
                if let p = app.addProfile(named: newName) { app.switchProfile(to: p.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The new profile starts with an empty collection. Sign in to AnkiWeb to download yours.")
        }
        .alert("Rename Profile", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let p = renaming { app.renameProfile(p.id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible)
        {
            Button("Delete Profile", role: .destructive) { if let p = deleting { app.deleteProfile(p.id) } }
        } message: {
            Text("Its collection and media on this device are deleted. Anything already synced stays on AnkiWeb.")
        }
    }

    private func account(_ profile: Profile) -> String {
        if Keychain.get(profile.key("hostKey")) == nil { return "Not signed in" }
        let name = UserDefaults.standard.string(forKey: profile.key("syncUsername")) ?? ""
        return name.isEmpty ? "Signed in" : name
    }
}

/// A round initial for a profile.
struct ProfileBadge: View {
    let name: String
    var size: CGFloat = 32

    private var color: Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red]
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return colors[sum % colors.count]
    }

    var body: some View {
        Text(String(name.first.map(String.init) ?? "?").uppercased())
            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .circle)
    }
}

/// Toolbar menu for switching profiles from the deck list.
struct ProfileMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            Section(app.profile.name) {
                ForEach(app.profiles) { profile in
                    Button {
                        app.switchProfile(to: profile.id)
                    } label: {
                        if profile.id == app.profile.id {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            }
            Button("Manage Profiles…", systemImage: "person.2") { app.selectedTab = .settings }
        } label: {
            ProfileBadge(name: app.profile.name, size: 28)
        }
        .accessibilityLabel("Profile: \(app.profile.name)")
    }
}
