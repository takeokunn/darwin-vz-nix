## Summary

- 

## Verification

- [ ] `nix flake check --system aarch64-darwin`
- [ ] `nix build .#checks.aarch64-linux.guest-artifacts` when guest artifacts changed
- [ ] `nix run .#smoke-test` on physical Apple Silicon macOS when VM boot, networking, SSH, or guest artifacts changed

## Notes

- 
