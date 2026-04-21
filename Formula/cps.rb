class Cps < Formula
  desc "Switch between isolated Claude Code profiles"
  homepage "https://github.com/guibes/claude-profile-switch"
  url "https://github.com/guibes/claude-profile-switch.git", tag: "v0.4.0"
  license "MIT"

  depends_on "git"

  def install
    bin.install "bin/cps"
    lib.install Dir["lib/*"]
    man1.install "man/cps.1"
    bash_completion.install "completions/cps.bash" => "cps"
    zsh_completion.install "completions/cps.zsh" => "_cps"

    inreplace bin/"cps", /^CPS_ROOT=.*$/, "CPS_ROOT=\"#{prefix}\""
  end

  def caveats
    <<~EOS
      Add to your shell rc file:
        eval "$(cps shell-init)"

      For Oh My Zsh:
        ln -sf #{prefix}/oh-my-zsh/cps #{ENV["ZSH_CUSTOM"] || "~/.oh-my-zsh/custom"}/plugins/cps
        # Add 'cps' to plugins=(...) in ~/.zshrc

      Optional: install 'age' for encrypted credential backup:
        brew install age
    EOS
  end

  test do
    assert_match "cps", shell_output("#{bin}/cps version")
  end
end
