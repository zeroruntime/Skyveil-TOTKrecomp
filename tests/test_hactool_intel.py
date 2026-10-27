"""Intel-only hactool cache patching; fixtures contain no game data or key material."""
import fnmatch
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import build_app


class HactoolIntelBignum(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / 'src/hactool'
        include = self.source / 'mbedtls/include/mbedtls'
        library = self.source / 'mbedtls/library'
        include.mkdir(parents=True)
        library.mkdir(parents=True)
        self.header = include / 'bn_mul.h'
        self.header.write_text(
            'before\n#if defined(__amd64__) || defined (__x86_64__)\n'
            '/* x86_64 inline MULADDC */\n#endif /* AMD64 */\nafter\n'
        )
        self.config = include / 'config.h'
        self.config.write_text('#define MBEDTLS_HAVE_ASM\n#define MBEDTLS_AESNI_C\n')
        for relative in (
            'mbedtls/library/bignum.o',
            'mbedtls/library/libmbedcrypto.a',
            'mbedtls/library/libmbedcrypto.dylib',
            'mbedtls/library/libmbedcrypto.so',
            'hactool',
            'mbedtls/library/aes.o',
            'mbedtls/library/libmbedx509.a',
        ):
            artifact = self.source / relative
            artifact.parent.mkdir(parents=True, exist_ok=True)
            artifact.write_bytes(b'cached')

    def test_intel_uses_portable_multiply_and_invalidates_only_dependent_outputs(self):
        self.assertTrue(build_app.patch_hactool_intel_bignum(self.source, 'x86_64'))

        patched = self.header.read_text()
        self.assertIn(build_app._HACTOOL_PORTABLE_MULADDC_SELECTOR, patched)
        self.assertNotIn(build_app._HACTOOL_AMD64_MULADDC_SELECTOR, patched)
        self.assertEqual(self.config.read_text(), '#define MBEDTLS_HAVE_ASM\n#define MBEDTLS_AESNI_C\n')
        self.assertEqual((self.source / '.mng-intel-portable-bignum-v1').read_text(),
                         'portable-muladdc-v1\n')

        for relative in ('mbedtls/library/bignum.o', 'mbedtls/library/libmbedcrypto.a',
                         'mbedtls/library/libmbedcrypto.dylib', 'mbedtls/library/libmbedcrypto.so', 'hactool'):
            self.assertFalse((self.source / relative).exists(), relative)
        for relative in ('mbedtls/library/aes.o', 'mbedtls/library/libmbedx509.a'):
            self.assertTrue((self.source / relative).is_file(), relative)

    def test_patch_is_idempotent_and_does_not_delete_outputs_rebuilt_afterward(self):
        build_app.patch_hactool_intel_bignum(self.source, 'x86_64')
        rebuilt = self.source / 'mbedtls/library/bignum.o'
        rebuilt.write_bytes(b'rebuilt')
        self.assertFalse(build_app.patch_hactool_intel_bignum(self.source, 'x86_64'))
        self.assertEqual(rebuilt.read_bytes(), b'rebuilt')

    def test_arm_host_leaves_pinned_source_and_cache_untouched(self):
        before = self.header.read_bytes()
        self.assertFalse(build_app.patch_hactool_intel_bignum(self.source, 'arm64'))
        self.assertEqual(self.header.read_bytes(), before)
        self.assertTrue((self.source / 'mbedtls/library/bignum.o').is_file())
        self.assertFalse((self.source / '.mng-intel-portable-bignum-v1').exists())

    def test_unrecognized_pinned_selector_fails_closed_before_cache_invalidation(self):
        self.header.write_text('upstream changed the x86_64 selector\n')
        with self.assertRaisesRegex(build_app.BuildError, 'x86_64 MULADDC selector changed'):
            build_app.patch_hactool_intel_bignum(self.source, 'x86_64')
        self.assertTrue((self.source / 'mbedtls/library/bignum.o').is_file())
        self.assertTrue((self.source / 'hactool').is_file())
        self.assertFalse((self.source / '.mng-intel-portable-bignum-v1').exists())

    def test_native_pss_accepts_a_valid_signature_and_rejects_corruption(self):
        """Compile a private copy of pinned mbedTLS and test its real RSA verifier with synthetic data."""
        if build_app.host_architecture() != 'x86_64':
            self.skipTest('the inline-assembly regression is specific to Intel hosts')
        if not shutil.which('make'):
            self.skipTest('make is required for the native crypto regression')
        source = build_app.REPO / 'game_essentials/TOTK_build/src/hactool'
        if not (source / 'mbedtls/include/mbedtls/bn_mul.h').is_file():
            self.skipTest('the pinned hactool source cache is unavailable')
        try:
            compiler = subprocess.run(['xcrun', '--find', 'clang'], capture_output=True, text=True)
            sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True)
        except OSError:
            self.skipTest('Xcode clang and the macOS SDK are required for the native crypto regression')
        if compiler.returncode or sdk.returncode or not Path(sdk.stdout.strip()).is_dir():
            self.skipTest('Xcode clang and the macOS SDK are required for the native crypto regression')

        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import padding, rsa

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            copied_source = root / 'hactool'

            def ignore_build_artifacts(_directory, names):
                return [name for name in names if any(fnmatch.fnmatch(name, pattern)
                                                       for pattern in ('*.o', '*.a', '*.dylib', '*.so*'))]

            shutil.copytree(source / 'mbedtls', copied_source / 'mbedtls', ignore=ignore_build_artifacts)
            shutil.copy2(source / 'config.mk', copied_source / 'config.mk')
            for name in ('rsa.c', 'rsa.h', 'sha.c', 'sha.h', 'types.h', 'utils.h'):
                shutil.copy2(source / name, copied_source / name)
            build_app.patch_hactool_intel_bignum(copied_source, 'x86_64')
            child_env = os.environ.copy()
            child_env['SDKROOT'] = sdk.stdout.strip()
            child_env['TMPDIR'] = str(root)
            build = subprocess.run(['make', '-C', str(copied_source / 'mbedtls'), 'lib',
                                    f'CC={shlex.quote(compiler.stdout.strip())} -isysroot '
                                    f'{shlex.quote(sdk.stdout.strip())}'],
                                   capture_output=True, text=True, env=child_env)
            self.assertEqual(build.returncode, 0, build.stderr[-3000:])

            harness = root / 'verify_pss.c'
            harness.write_text(r'''#include <stdio.h>
#include <stdlib.h>
#include "rsa.h"

static unsigned char *read_file(const char *path, size_t *size) {
    FILE *file = fopen(path, "rb");
    if (!file || fseek(file, 0, SEEK_END)) return NULL;
    long length = ftell(file);
    if (length < 0 || fseek(file, 0, SEEK_SET)) return NULL;
    unsigned char *data = malloc((size_t)length);
    if (!data || fread(data, 1, (size_t)length, file) != (size_t)length) return NULL;
    fclose(file);
    *size = (size_t)length;
    return data;
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    size_t data_size, signature_size, modulus_size;
    unsigned char *data = read_file(argv[1], &data_size);
    unsigned char *signature = read_file(argv[2], &signature_size);
    unsigned char *modulus = read_file(argv[3], &modulus_size);
    if (!data || !signature || !modulus || signature_size != 256 || modulus_size != 256) return 3;
    int valid = rsa2048_pss_verify(data, data_size, signature, modulus);
    puts(valid ? "PSS PASS" : "PSS FAIL");
    free(data); free(signature); free(modulus);
    return valid ? 0 : 1;
}
''')
            data = b'hactool Intel bignum regression fixture'
            private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            signature = private_key.sign(data, padding.PSS(mgf=padding.MGF1(hashes.SHA256()),
                                                            salt_length=32), hashes.SHA256())
            modulus = private_key.public_key().public_numbers().n.to_bytes(256, 'big')
            paths = [root / name for name in ('message.bin', 'signature.bin', 'modulus.bin')]
            for path, contents in zip(paths, (data, signature, modulus)):
                path.write_bytes(contents)

            executable = root / 'verify_pss'
            compiled = subprocess.run([compiler.stdout.strip(), '-isysroot', sdk.stdout.strip(), '-O2', '-I', str(copied_source),
                                       '-I', str(copied_source / 'mbedtls/include'), str(harness),
                                       str(copied_source / 'rsa.c'), str(copied_source / 'sha.c'),
                                       str(copied_source / 'mbedtls/library/libmbedcrypto.a'),
                                       '-o', str(executable)], capture_output=True, text=True, env=child_env)
            self.assertEqual(compiled.returncode, 0, compiled.stderr[-3000:])

            valid = subprocess.run([str(executable), *(str(path) for path in paths)],
                                   capture_output=True, text=True)
            self.assertEqual((valid.returncode, valid.stdout.strip()), (0, 'PSS PASS'))

            corrupt_signature = bytearray(signature)
            corrupt_signature[0] ^= 1
            paths[1].write_bytes(corrupt_signature)
            invalid = subprocess.run([str(executable), *(str(path) for path in paths)],
                                     capture_output=True, text=True)
            self.assertEqual((invalid.returncode, invalid.stdout.strip()), (1, 'PSS FAIL'))


if __name__ == '__main__':
    unittest.main()
