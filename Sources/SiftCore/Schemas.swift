import Foundation

/// FtM schema groups used by the research tools. Mirrors sift's
/// schemas.py and AilephCore/Commands.swift so the agent's `type=`
/// shorthand maps to the same `filter:schemata` lists.
public enum Schemas {
    public static let typeToSchema: [String: String] = [
        "emails": "Email",
        "docs": "Document",
        "web": "HyperText",
        "people": "Person",
        "orgs": "Organization",
    ]

    public static let anyTypeSchemas: [String] = ["Document", "Email", "HyperText"]

    public static let partySchemas: Set<String> = [
        "Person", "LegalEntity", "Organization", "Company", "PublicBody", "Address",
    ]

    public static let folderSchemas: Set<String> = [
        "Folder", "Package", "Directory", "Workbook",
    ]

    public static let treeDocSchemas: [String] = [
        "Folder", "Package", "Workbook", "Document", "HyperText",
        "PlainText", "Pages", "Image", "Video", "Audio", "Table", "Email",
    ]

    public static let refProperties: [String] = [
        "emitters", "recipients", "ccRecipients", "bccRecipients",
        "sender", "inReplyTo", "mentions", "mentionedEntities",
        "owner", "asset", "parent",
    ]

    /// Properties whose bare-string list members are entity ids, not labels.
    public static let bareStringRefProps: Set<String> = {
        var s = Set(refProperties)
        s.insert("ancestors")
        return s
    }()
}
