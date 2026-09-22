TERMUX_PKG_HOMEPAGE=https://github.com/bensadeh/tailspin
TERMUX_PKG_DESCRIPTION="A log file highlighter"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@ih532268-cell <283420161+ih532268-cell@users.noreply.github.com>"
TERMUX_PKG_VERSION="7.0.0"
TERMUX_PKG_SRCURL="https://github.com/bensadeh/tailspin/archive/refs/tags/${TERMUX_PKG_VERSION}.tar.gz"
TERMUX_PKG_SHA256=45fafd0b3b43de6490a1a4a86a071f0db3d2a8e3f260b50def131c6996a2930e
TERMUX_PKG_DEPENDS="less"
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_BUILD_IN_SRC=true

termux_step_make() {
	termux_setup_rust

	cargo build \
		--jobs "$TERMUX_PKG_MAKE_PROCESSES" \
		--target "$CARGO_TARGET_NAME" \
		--release
}

termux_step_make_install() {
	install -Dm755 -t "$TERMUX_PREFIX"/bin \
		"target/${CARGO_TARGET_NAME}/release/tspin"
}
