import Foundation

/// Builds the handle → contact lookup indexes with ambiguity detection.
///
/// A lookup key claimed by TWO OR MORE distinct Contacts cards (a shared
/// family landline, a work main line on several cards, one email on two
/// cards) is dropped from every index: resolving it to either card would be a
/// guess, a wrong name in the UI, and a potential false merge — and which
/// card "won" used to depend on CNContactStore enumeration order, so the
/// outcome could flip between launches. Dropped keys degrade to handle-level
/// identity, which is deterministic by construction and order-independent.
///
/// Both resolvers (import-time and display-time) MUST build through this type
/// so ambiguity is decided identically everywhere.
struct ContactIndexBuilder {
    struct Indexes {
        let phoneIndex: [String: String]
        let emailIndex: [String: String]
        let contactIdentifierIndex: [String: String]
        let imageIndex: [String: Data]
    }

    private struct Claim {
        var contactIdentifier: String
        var displayName: String
        var image: Data?
        var isAmbiguous = false
    }

    private var claims: [String: Claim] = [:]

    mutating func add(
        contactIdentifier: String,
        displayName: String,
        phoneNumbers: [String],
        emailAddresses: [String],
        image: Data? = nil
    ) {
        var keys: [String] = []
        for number in phoneNumbers {
            keys.append(contentsOf: ContactDisplayResolver.phoneLookupKeys(for: number))
        }
        for email in emailAddresses {
            let key = email.trimmed.lowercased()
            if !key.isEmpty {
                keys.append(key)
            }
        }

        for key in keys {
            if var existing = claims[key] {
                if existing.contactIdentifier != contactIdentifier {
                    existing.isAmbiguous = true
                    claims[key] = existing
                }
                continue
            }
            claims[key] = Claim(contactIdentifier: contactIdentifier, displayName: displayName, image: image)
        }
    }

    func finalize() -> Indexes {
        var phoneIndex: [String: String] = [:]
        var emailIndex: [String: String] = [:]
        var idIndex: [String: String] = [:]
        var imageIndex: [String: Data] = [:]

        for (key, claim) in claims {
            guard !claim.isAmbiguous else { continue }
            if key.contains("@") {
                emailIndex[key] = claim.displayName
            } else {
                phoneIndex[key] = claim.displayName
            }
            idIndex[key] = claim.contactIdentifier
            if let image = claim.image {
                imageIndex[key] = image
            }
        }

        return Indexes(
            phoneIndex: phoneIndex,
            emailIndex: emailIndex,
            contactIdentifierIndex: idIndex,
            imageIndex: imageIndex
        )
    }
}
