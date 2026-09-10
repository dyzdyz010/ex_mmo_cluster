#!/usr/bin/env bash
set -euo pipefail
# 当前部署固定为 OTP27 x86_64；只安装已验过的官方 NIF，不隐式切换本地源码构建。
test "$(erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().')" = 27
test "$(uname -m)" = x86_64
package=libquicer-0.4.3-otp27-quictls-ubuntu22.04-x86_64.gz
archive=${QUICER_NATIVE_ARCHIVE:-"$PWD/_packages/$package"}
if [ ! -f "$archive" ]; then
  mkdir -p "$(dirname "$archive")"
  curl --fail --location --proto '=https' --tlsv1.2 "https://github.com/emqx/quic/releases/download/0.4.3/$package" -o "$archive"
fi
echo "a8784aeeef8b40ae2c88ac234056b4d7c2d7d82c1df78b4a15d24a7fc2554503  $archive" | sha256sum -c -
mkdir -p priv ebin
tar xzf "$archive" -C priv
echo 'bf515a1701341238d25441cde9f932a7c86ca46f327cfad2e92069cf4392d32a  priv/libquicer_nif.so' | sha256sum -c -
sed 's/@QUICER_ABI_VERSION@/1/' templates/quicer_vsn.hrl.in > include/quicer_vsn.hrl
erlc -I include -pa ebin -o ebin src/*.erl
sed 's/{vsn, "git"}/{vsn, "0.4.3"}/' src/quicer.app.src > ebin/quicer.app
