'use strict';
// Headless CoShare device on the Node engine, for interop tests with the Swift apps (Tools/TestPeer).
// Commands are read from $COSHARE_CMDS, one per line:
//   create <group> <password> · join <group> <password> · leave <group> · copy <text> · copyimg <file.png>
//   peers · groups · history · quietnow <minutes> · resume · state · quit
const fs = require('fs');
const os = require('os');
const path = require('path');
const { SyncEngine } = require('../src/core/engine');

const env = process.env;
const dataDir = env.COSHARE_DATA || fs.mkdtempSync(path.join(os.tmpdir(), 'coshare-peer-'));
fs.mkdirSync(dataDir, { recursive: true });
const say = (line) => console.log(line);

// In-memory clipboard: copy commands change it, incoming clips are printed.
const clip = { token: 0, content: null };
const clipboard = {
  changeToken: () => clip.token,
  read: () => clip.content,
  write: (content) => {
    clip.content = content; clip.token++;
    say(`PASTEBOARD <- ${content.kind === 'text' ? `text "${content.text}"` : `image ${content.uti} ${content.data.length} bytes`}`);
  },
};

const engine = new SyncEngine({
  dataDir, clipboard, platform: env.COSHARE_PLATFORM || 'linux', defaultName: env.COSHARE_NAME || 'NodePeer',
  verbose: !!env.COSHARE_VERBOSE,
  env: { port: env.COSHARE_PORT ? Number(env.COSHARE_PORT) : undefined, noBonjour: !!env.COSHARE_NO_BONJOUR,
    extraHosts: (env.COSHARE_HOSTS || '').split(',').filter(Boolean) },
});
engine.start();

const commandsFile = env.COSHARE_CMDS || path.join(dataDir, 'commands.txt');
if (!fs.existsSync(commandsFile)) fs.writeFileSync(commandsFile, '');
let processed = 0;
setInterval(async () => {
  const lines = fs.readFileSync(commandsFile, 'utf8').split('\n').filter(Boolean);
  for (const line of lines.slice(processed)) {
    processed++;
    say(`> ${line}`);
    const [cmd, ...rest] = line.split(' ');
    const arg = rest.join(' ');
    try {
      if (cmd === 'create') { engine.createGroup(rest[0], rest[1]); say('CREATE ok'); }
      else if (cmd === 'join') {
        const nearby = engine.nearbyGroups().find((n) => n.group.name === rest[0]);
        if (!nearby) { say('JOIN no such group'); continue; }
        await engine.join(nearby.key, rest[1]); say(`JOIN ok ${rest[0]}`);
      }
      else if (cmd === 'leave') { const g = engine.settings.get('groups').find((x) => x.name === arg); if (g) engine.leave(g.id); say('LEAVE ok'); }
      else if (cmd === 'copy') { clip.content = { kind: 'text', text: arg }; clip.token++; }
      else if (cmd === 'copyimg') { clip.content = { kind: 'image', data: fs.readFileSync(arg), uti: 'public.png' }; clip.token++; }
      else if (cmd === 'peers') say('PEERS ' + engine.peers.map((p) => `${p.name}[${p.platform},${p.isDirect ? 'direct' : 'bonjour'}]`).join(', ') + ' | CONNECTED ' + engine.connectedPeers().map((p) => p.name).join(', '));
      else if (cmd === 'groups') say('GROUPS ' + engine.settings.get('groups').map((g) => `${g.name}[${engine.membersOf(g.id).map((p) => p.name).join(',')}]`).join(' '));
      else if (cmd === 'history') engine.history.items.forEach((i) => say(`HISTORY ${i.direction} ${i.kind} from=${i.deviceName} ${i.text || i.byteCount + ' bytes'} delivered=${i.deliveredTo}`));
      else if (cmd === 'quietnow') {
        const now = new Date(); const start = now.getHours() * 60 + now.getMinutes();
        engine.setSetting('quietSchedule', { days: [1, 2, 3, 4, 5, 6, 7], start, end: (start + (Number(arg) || 2)) % 1440 });
        engine.setSetting('quietEnabled', true);
      }
      else if (cmd === 'resume') engine.resumeToday();
      else if (cmd === 'state') say(`STATE ${engine.presence.state}`);
      else if (cmd === 'quit') process.exit(0);
      else say('unknown command');
    } catch (error) { say(`ERROR ${error.message}`); }
  }
}, 300);
say(`READY name=${engine.settings.get('deviceName')} data=${dataDir}`);
