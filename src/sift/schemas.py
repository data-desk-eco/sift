"""Schema groups (matches AilephCore/Commands.swift).

Aleph entities are typed by FtM schema. We group them so the user-facing
`type=` shorthand maps to the right `filter:schemata` for the API, and so
schema-shape branches in the commands stay readable.
"""

from __future__ import annotations

TYPE_TO_SCHEMA = {
    "emails": "Email",
    "docs": "Document",
    "web": "HyperText",
    "people": "Person",
    "orgs": "Organization",
}
ANY_TYPE_SCHEMAS = ["Document", "Email", "HyperText"]
PARTY_SCHEMAS = {
    "Person", "LegalEntity", "Organization", "Company", "PublicBody", "Address",
}
FOLDER_SCHEMAS = {"Folder", "Package", "Directory", "Workbook"}
TREE_DOC_SCHEMAS = [
    "Folder", "Package", "Workbook", "Document", "HyperText",
    "PlainText", "Pages", "Image", "Video", "Audio", "Table", "Email",
]
REF_PROPERTIES = [
    "emitters", "recipients", "ccRecipients", "bccRecipients",
    "sender", "inReplyTo", "mentions", "mentionedEntities",
    "owner", "asset", "parent",
]
