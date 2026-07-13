const rl = require('readline').createInterface({ input: process.stdin, output: process.stdout });
rl.question('', (pw) => { console.log(encodeURIComponent(pw)); rl.close(); });
