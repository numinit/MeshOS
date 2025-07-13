# MeshOS

**This repository is experimental, and all APIs are subject to change.**

Current goals:

- Security of layers 2-7 as a top priority, through picking good standards.
- Layer 2: BATMAN running over 802.11s, encrypted with WPA3-SAE, with 802.11w management frame protection
- Layer 3: Nebula VPN, based on the Noise protocol
- Layer 7: Nix binary cache using Nix Cache Proxy Server (Go)
- Tests simulating the entire hardware stack, including 802.11s wifi, the TPM used in key negotiation, and nodes that already have cached data.

Current non-goals:

- Being a router, including running DNS and NTP servers. Any router API this project has would likely be worse UX than just using OpenWRT.
    - My routers are configured in a way that works for me(tm) and I really don't want to inflict it on anyone else.
- Remote builders and user support, though this may change.
- Hardware-specific quirks, like setting up modems and customizing wifi chipset firmware.
