# Nobby

Nobby is a nostalgic bulletin board server for Nim.

I grew up on the early internet, when many communities had their own small forums.
There were boards for OS development, game development, flat assembler, and almost every other topic.
Those spaces were simple, focused, and full of useful information.
Today most discussion is centralized on social media, but I wanted that old style back.

Nobby is my take on the classic phpBB era, built with modern Nim tools instead of old PHP stacks.
It is a simple bulletin board inspired by early-2000s web forums.

## Why Nobby

- Bring back small community-owned bulletin boards.
- Keep the stack simple and easy to understand.
- Prefer server-rendered HTML over complex client-side loading.
- Build with Nim and libraries I trust.

## Stack

- `mummy` for the HTTP server.
- `debby` for data storage.
- `taggy` for server-side HTML generation.

Nobby favors old-fashioned, server-rendered pages that are easy to inspect and reason about.
Simple HTML is still fast, reliable, and pleasant to work with.

## Install

```bash
nimble install nobby
```
