import {copyFile,mkdir,access} from 'node:fs/promises';
await mkdir('public',{recursive:true});
// The hosted library uses the same palette and controls as the local studio.
for (const [from,to] of [['../web/assets/app.css','public/app.css'],['../web/assets/icon.svg','public/icon.svg'],['lib/vault.js','public/vault.js']]) { try { await access(from); await copyFile(from,to); } catch(error) { if(from.startsWith('../')) await access(to); else throw error; } }
