"""sift — investigative research agent for OCCRP Aleph or OpenAleph.

Layout: cli.py is the Click entry point. The data plane (commands,
client, store, render, schemas) implements Aleph's research surface;
vault.py owns the encrypted sparseimage; backend.py owns LLM-backend
config and the local llama-server lifecycle. Per-package data files
(AGENTS.md, SKILL.md, touchid.swift) live under data/."""

__version__ = "0.2.0"
