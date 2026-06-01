import Foundation

/// A curated slice of the [FollowTheMoney](https://followthemoney.tech)
/// data model — the same schema Aleph itself uses. The agent records its
/// structured findings as proper FtM entities (a `Payment`, an
/// `Ownership`, a `Person`) rather than ad-hoc tables, so the findings
/// are browsable, joinable, and exportable straight into Aleph.
///
/// This is deliberately not the full registry (~60 schemas). It covers
/// the investigative schemas an agent reaching for structured findings
/// actually needs, with their properties flattened (inherited props
/// merged in). Validation is *forgiving*: an unknown property on a known
/// schema is kept with a warning rather than rejected, so a gap here
/// never blocks the agent — but unknown *schemas* are rejected, because
/// that's almost always a typo we can help fix.
public enum Ftm {

    /// Coarse FtM property types. We don't enforce most of them — the one
    /// that matters operationally is `.entity`, whose values are entity
    /// references (other findings `f3`, Aleph entities `r5`, or raw ids)
    /// and get alias-resolved on write and re-aliased on render.
    public enum PropType: String, Sendable {
        case string, name, text, date, country, identifier, number
        case url, email, phone, topic, address, language, entity
    }

    public struct SchemaDef: Sendable {
        public let name: String
        public let label: String
        /// True for relationship schemas (Ownership, Payment, …) that
        /// connect two entities. `source`/`target` name the endpoint
        /// properties.
        public let isEdge: Bool
        public let source: String?
        public let target: String?
        public let props: [String: PropType]

        public var entityProps: Set<String> {
            Set(props.filter { $0.value == .entity }.map(\.key))
        }
    }

    // MARK: - Shared property groups (flattened inheritance)

    private static let thing: [String: PropType] = [
        "name": .name, "alias": .name, "weakAlias": .name, "previousName": .name,
        "summary": .text, "description": .text, "notes": .text, "keywords": .string,
        "country": .country, "address": .address, "sourceUrl": .url,
        "publisher": .string, "wikidataId": .identifier, "modifiedAt": .date,
    ]

    private static let legalEntity: [String: PropType] = thing.merging([
        "email": .email, "phone": .phone, "website": .url,
        "legalForm": .string, "status": .string, "sector": .string,
        "classification": .string, "registrationNumber": .identifier,
        "idNumber": .identifier, "taxNumber": .identifier, "vatCode": .identifier,
        "jurisdiction": .country, "mainCountry": .country,
        "incorporationDate": .date, "dissolutionDate": .date,
        "title": .string,
    ]) { _, new in new }

    /// Interval — the base for edge schemas. `date`/`startDate`/`endDate`
    /// plus a `role` describing the relationship.
    private static let interval: [String: PropType] = [
        "startDate": .date, "endDate": .date, "date": .date,
        "summary": .text, "description": .text, "role": .string,
        "recordId": .identifier, "sourceUrl": .url, "publisher": .string,
    ]

    private static let value: [String: PropType] = [
        "amount": .number, "currency": .string,
        "amountEur": .number, "amountUsd": .number,
    ]

    private static func merge(_ groups: [String: PropType]...) -> [String: PropType] {
        var out: [String: PropType] = [:]
        for g in groups { for (k, v) in g { out[k] = v } }
        return out
    }

    // MARK: - The registry

    public static let registry: [SchemaDef] = [
        // ---- Parties (Thing / LegalEntity) ----
        SchemaDef(name: "Person", label: "Person", isEdge: false, source: nil, target: nil,
            props: merge(legalEntity, [
                "firstName": .name, "lastName": .name, "middleName": .name,
                "secondName": .name, "fatherName": .name, "motherName": .name,
                "nationality": .country, "gender": .string, "birthDate": .date,
                "birthPlace": .string, "deathDate": .date, "position": .string,
                "religion": .string, "ethnicity": .string, "education": .string,
                "political": .string, "passportNumber": .identifier,
                "socialSecurityNumber": .identifier,
            ])),
        SchemaDef(name: "Organization", label: "Organization", isEdge: false, source: nil, target: nil,
            props: legalEntity),
        SchemaDef(name: "Company", label: "Company", isEdge: false, source: nil, target: nil,
            props: merge(legalEntity, [
                "capital": .number, "ticker": .identifier, "ipoDate": .date,
                "cikCode": .identifier, "irsCode": .identifier, "ricCode": .identifier,
            ])),
        SchemaDef(name: "PublicBody", label: "Public body", isEdge: false, source: nil, target: nil,
            props: legalEntity),
        SchemaDef(name: "LegalEntity", label: "Legal entity", isEdge: false, source: nil, target: nil,
            props: legalEntity),

        // ---- Assets ----
        SchemaDef(name: "Asset", label: "Asset", isEdge: false, source: nil, target: nil,
            props: merge(thing, value, ["ownershipStatus": .string])),
        SchemaDef(name: "Security", label: "Security", isEdge: false, source: nil, target: nil,
            props: merge(thing, value, [
                "isin": .identifier, "ticker": .identifier, "registationNumber": .identifier,
                "issuer": .entity, "type": .string, "maturityDate": .date,
            ])),
        SchemaDef(name: "RealEstate", label: "Real estate", isEdge: false, source: nil, target: nil,
            props: merge(thing, value, [
                "registrationNumber": .identifier, "area": .string,
                "tenure": .string, "propertyType": .string,
            ])),
        SchemaDef(name: "Vehicle", label: "Vehicle", isEdge: false, source: nil, target: nil,
            props: merge(thing, ["registrationNumber": .identifier, "type": .string,
                "model": .string, "year": .number])),

        // ---- Accounts / identity ----
        SchemaDef(name: "BankAccount", label: "Bank account", isEdge: false, source: nil, target: nil,
            props: merge(thing, value, [
                "accountNumber": .identifier, "iban": .identifier, "bic": .identifier,
                "bankName": .name, "holder": .entity, "accountType": .string,
                "balance": .number,
            ])),
        SchemaDef(name: "Address", label: "Address", isEdge: false, source: nil, target: nil,
            props: [
                "full": .address, "street": .string, "city": .string,
                "postalCode": .string, "region": .string, "state": .string,
                "country": .country, "latitude": .number, "longitude": .number,
            ]),
        SchemaDef(name: "Identification", label: "Identification", isEdge: false, source: nil, target: nil,
            props: merge(interval, [
                "holder": .entity, "number": .identifier, "type": .string,
                "country": .country, "authority": .string,
            ])),

        // ---- Events ----
        SchemaDef(name: "Event", label: "Event", isEdge: false, source: nil, target: nil,
            props: merge(thing, interval, [
                "location": .string, "involved": .entity, "organizer": .entity,
                "actor": .entity,
            ])),

        // ---- Relationships (edges) ----
        SchemaDef(name: "Ownership", label: "Ownership", isEdge: true, source: "owner", target: "asset",
            props: merge(interval, [
                "owner": .entity, "asset": .entity, "percentage": .number,
                "sharesCount": .number, "sharesValue": .number, "sharesCurrency": .string,
                "sharesType": .string, "legalBasis": .string, "ownershipType": .string,
            ])),
        SchemaDef(name: "Directorship", label: "Directorship", isEdge: true, source: "director", target: "organization",
            props: merge(interval, ["director": .entity, "organization": .entity])),
        SchemaDef(name: "Membership", label: "Membership", isEdge: true, source: "member", target: "organization",
            props: merge(interval, ["member": .entity, "organization": .entity])),
        SchemaDef(name: "Employment", label: "Employment", isEdge: true, source: "employer", target: "employee",
            props: merge(interval, ["employer": .entity, "employee": .entity, "contractType": .string])),
        SchemaDef(name: "Associate", label: "Associate", isEdge: true, source: "person", target: "associate",
            props: merge(interval, ["person": .entity, "associate": .entity, "relationship": .string])),
        SchemaDef(name: "Family", label: "Family", isEdge: true, source: "person", target: "relative",
            props: merge(interval, ["person": .entity, "relative": .entity, "relationship": .string])),
        SchemaDef(name: "Representation", label: "Representation", isEdge: true, source: "agent", target: "client",
            props: merge(interval, ["agent": .entity, "client": .entity])),
        SchemaDef(name: "Payment", label: "Payment", isEdge: true, source: "payer", target: "beneficiary",
            props: merge(interval, value, [
                "payer": .entity, "beneficiary": .entity,
                "payerAccount": .entity, "beneficiaryAccount": .entity,
                "purpose": .text, "programme": .string,
                "sequenceNumber": .identifier, "transactionNumber": .identifier,
                "contract": .entity, "project": .entity,
            ])),
        SchemaDef(name: "Documentation", label: "Documentation", isEdge: true, source: "entity", target: "document",
            props: merge(interval, ["entity": .entity, "document": .entity])),
        SchemaDef(name: "UnknownLink", label: "Unknown link", isEdge: true, source: "subject", target: "object",
            props: merge(interval, ["subject": .entity, "object": .entity])),
    ]

    private static let byName: [String: SchemaDef] = {
        var m: [String: SchemaDef] = [:]
        // Last definition wins; the registry has no real dupes but the
        // map dedupes defensively.
        for def in registry { m[def.name] = def }
        return m
    }()

    private static let byLowerName: [String: SchemaDef] = {
        var m: [String: SchemaDef] = [:]
        for def in registry { m[def.name.lowercased()] = def }
        return m
    }()

    /// Resolve a schema name, tolerating case differences (`payment` →
    /// `Payment`). Returns nil for genuinely unknown schemas.
    public static func schema(_ name: String) -> SchemaDef? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return byName[trimmed] ?? byLowerName[trimmed.lowercased()]
    }

    public static var schemaNames: [String] {
        registry.map(\.name).sorted()
    }

    // MARK: - Value coercion

    /// FtM property values are always arrays of strings. Squash whatever
    /// the caller passed (scalar, number, nested array) into that shape,
    /// dropping empties.
    public static func coerce(_ value: Any?) -> [String] {
        switch value {
        case nil, is NSNull:
            return []
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [t]
        case let n as NSNumber:
            return [n.stringValue]
        case let arr as [Any]:
            return arr.flatMap { coerce($0) }
        default:
            return ["\(value!)"]
        }
    }

    public struct Normalized: Sendable {
        public let schema: String
        public let properties: [String: [String]]
        public let warnings: [String]
    }

    /// Validate a schema name and coerce a raw properties dict into FtM
    /// shape. Throws on an unknown schema (with a suggestion); collects a
    /// warning per unknown-but-kept property.
    public static func normalize(schema rawSchema: String, properties raw: [String: Any]) throws -> Normalized {
        guard let def = schema(rawSchema) else {
            throw SiftError(
                "unknown FtM schema '\(rawSchema)'",
                suggestion: "run `sift entity schemas` to list valid schemas"
            )
        }
        var out: [String: [String]] = [:]
        var warnings: [String] = []
        // Stable iteration so warnings/order are deterministic.
        for key in raw.keys.sorted() {
            let vals = coerce(raw[key])
            guard !vals.isEmpty else { continue }
            if def.props[key] == nil {
                warnings.append(
                    "'\(key)' is not a property of \(def.name) — kept anyway; see `sift entity schemas \(def.name)`"
                )
            }
            out[key, default: []].append(contentsOf: vals)
        }
        return Normalized(schema: def.name, properties: out, warnings: warnings)
    }
}
