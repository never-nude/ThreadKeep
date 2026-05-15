import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @AppStorage("threadkeep.import.useContactsNames") private var useContactsNames = true
    @State private var isConfirmingDeleteAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About ThreadKeep")
                        .font(.title2.bold())
                    Text("ThreadKeep turns the Messages already on your Mac into a simple library you can browse, search, and revisit.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("How ThreadKeep Works")
                        .font(.headline)
                    Text("Here is the simple version:")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Label("Your library is kept on this Mac unless you choose to share a copy.", systemImage: "lock.shield")
                        .font(.system(size: 12))
                    Label("You do not need an account to use ThreadKeep.", systemImage: "person.crop.circle.badge.xmark")
                        .font(.system(size: 12))
                    Label("Showing saved contact names is optional. If you leave it off, labels stay as phone numbers and email addresses.", systemImage: "person.text.rectangle")
                        .font(.system(size: 12))
                    Label("If you export a PDF or send something to iPhone, that happens only when you choose it.", systemImage: "hand.tap")
                        .font(.system(size: 12))
                    Text("ThreadKeep is meant to feel like your own Messages library on Mac, with sharing available only when you want it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Storage")
                        .font(.headline)
                    Text("Your library and saved files are stored in a folder on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Show Library Folder") {
                        viewModel.openDataFolder()
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Conversation Labels")
                        .font(.headline)
                    Toggle("Show saved contact names when available", isOn: contactsOptInBinding)
                    Text("When this is on, ThreadKeep uses Contacts on this Mac to show saved names where it can. If they are not available, it simply shows phone numbers or email addresses instead.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Library Management")
                        .font(.headline)
                    Text("You can remove the conversations currently saved in ThreadKeep from this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Button("Delete All Imported Conversations", role: .destructive) {
                            isConfirmingDeleteAll = true
                        }
                        .disabled(viewModel.isBusy)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 420)
        .confirmationDialog(
            "Delete every imported conversation from this Mac?",
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                Task { await viewModel.deleteAllArchives() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the conversations currently saved in ThreadKeep from this Mac.")
        }
    }

    private var contactsOptInBinding: Binding<Bool> {
        Binding(
            get: { useContactsNames },
            set: { newValue in
                useContactsNames = newValue
            }
        )
    }
}
