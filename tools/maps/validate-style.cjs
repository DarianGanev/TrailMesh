// Complete pinned MapLibre specification validation, including finalized terrain style.
const {validateStyleMin} = require('@maplibre/maplibre-gl-style-spec');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {execFileSync} = require('node:child_process');
function check(file) {
  const errors = validateStyleMin(JSON.parse(fs.readFileSync(file, 'utf8')));
  if (errors.length) throw Error(file + '\n' + errors.map(e => e.message).join('\n'));
}
const supplied = process.argv.slice(2);
if (supplied.length) supplied.forEach(check);
else {
  check(path.join(__dirname, 'style.json'));
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'trailmesh-style-'));
  try {
    fs.mkdirSync(path.join(temporary, 'pack'));
    fs.copyFileSync(path.join(__dirname, 'style.json'), path.join(temporary, 'pack/style.json'));
    fs.writeFileSync(path.join(temporary, 'pack/terrain.pmtiles'), 'fixture');
    execFileSync(process.env.PYTHON || 'python', ['-c', 'from finalize import finalize_style; from pathlib import Path; import sys; finalize_style(Path(sys.argv[1]))', temporary], {cwd: __dirname});
    check(path.join(temporary, 'pack/style.json'));
    // Regression: the legacy !in operator must never accept expression operands.
    const invalid = JSON.parse(fs.readFileSync(path.join(__dirname, 'style.json'), 'utf8'));
    invalid.layers.find(layer => layer.id === 'roads').filter = ['!in', ['get', 'class'], ['literal', ['path', 'track']]];
    if (!validateStyleMin(invalid).length) throw Error('Malformed road filter escaped complete validation');
  } finally { fs.rmSync(temporary, {recursive:true, force:true}); }
}
console.log('MapLibre styles validated');
