# Jay's Dotfiles

Requires GNU Stow `sudo apt install stow`/`nix-env -iA nixpkgs.stow`

Simply `stow $PKGNAME` to add all dotfiles for PKGNAME

## Chezmoi

Over time, I am migrating things to [chezmoi](https://www.chezmoi.io/) 

- Install: `nix-env -iA nixpkgs.chezmoi`
- Initialize: `chezmoi init https://github.com/...`
- Look at changes: `chezmoi diff`
- Apply changes: `chezmoi apply`
  - Note: `chezmoi apply -nv` is useful to know what would be updated without actually updating it.

## Emacs config

My custom hand-rolled config works with `stow emacs`, but I am currently in the
process of testing out (or indeed switching to) Doom Emacs. That takes a tiny
bit more effort to set up:

```sh
stow doom-emacs
git clone --depth 1 https://github.com/doomemacs/doomemacs ~/.emacs.d
~/.emacs.d/bin/doom install --no-hooks # Say no to hooks, but say yes to all else
~/.emacs.d/bin/doom doctor
```

Whenever changes are made to `~/.doom.d`, run `doom sync` and restart Emacs
(`C-c q r`). Run `doom upgrade` to update Doom itself.

If you end up with a blank screen, it is likely due to missing fonts (try 
`emacs --debug-init` to confirm). If so, run this:

```sh
wget https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Iosevka.zip
unzip Iosevka.zip
mv Iosevka*.ttf ~/.local/share/fonts/
fc-cache --force --verbose
```

## Connecting PDF inverse search into WSL:

```
"C:\Program Files\WSL\wslg.exe" -- "/home/jayb/.local/bin/emacsclient_from_windows" --no-wait +%l "%f"
```
