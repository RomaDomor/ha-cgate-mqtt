#!/usr/bin/env node

const mqtt = require('mqtt');
const url = require('url');
const net = require('net');
const { EventEmitter } = require('events');
const settings = require('./settings.js');
const { parseString } = require('xml2js');

const options = { retain: !!settings.retainreads };
const messageInterval = settings.messageinterval || 200;
const logging = !!settings.logging;

let tree = '';
let treenet = 0;
let buffer = '';
let commandConnected = false;
let eventConnected = false;
let clientConnected = false;

const eventEmitter = new EventEmitter();

const HOST = settings.cbusip;
const COMPORT = 20023;
const EVENTPORT = 20025;

// MQTT connection options
const mqttUrl = `mqtt://${settings.mqtt}`;
const mqttOptions = {};
if (settings.mqttusername && settings.mqttpassword) {
    mqttOptions.username = settings.mqttusername;
    mqttOptions.password = settings.mqttpassword;
}

// MQTT client
const client = mqtt.connect(mqttUrl, mqttOptions);

// TCP sockets
const command = new net.Socket();
const event = new net.Socket();

// Queues for MQTT and command writes
const createQueue = (action) => ({
    queue: [],
    interval: null,
    push(item) {
        this.queue.push(item);
        if (!this.interval) {
            this.interval = setInterval(() => this.process(), messageInterval);
            this.process();
        }
    },
    process() {
        if (!this.queue.length) {
            clearInterval(this.interval);
            this.interval = null;
            return;
        }
        action(this.queue.shift());
    },
});

const mqttQueue = createQueue(({ topic, payload, opts }) => {
    client.publish(topic, payload, opts || options);
});

const commandQueue = createQueue((cmd) => {
    command.write(cmd);
});

// Connection logic
const started = () => {
    if (commandConnected && eventConnected && clientConnected) {
        console.log('ALL CONNECTED');
        if (settings.getallnetapp && settings.getallonstart) {
            console.log('Getting all values');
            commandQueue.push(`GET //${settings.cbusname}/${settings.getallnetapp}/* level\n`);
        }
        if (settings.getallnetapp && settings.getallperiod) {
            setInterval(() => {
                console.log('Getting all values');
                commandQueue.push(`GET //${settings.cbusname}/${settings.getallnetapp}/* level\n`);
            }, settings.getallperiod * 1000);
        }
    }
};

// MQTT event handlers
client.on('connect', () => {
    clientConnected = true;
    console.log(`CONNECTED TO MQTT: ${settings.mqtt}`);
    started();

    client.subscribe('cbus/write/#', (err) => {
        if (err) {
            console.error('MQTT subscribe error:', err);
            return;
        }
        client.on('message', handleMqttMessage);
    });

    mqttQueue.push({ topic: 'hello/world', payload: 'CBUS ON' });
});

client.on('disconnect', () => {
    clientConnected = false;
});

// MQTT message handler
function handleMqttMessage(topic, message) {
    if (logging) console.log(`Message received on ${topic} : ${message}`);
    const parts = topic.split('/');
    if (parts.length <= 5) return;

    const [, , net, app, group, action] = parts;
    const msg = message.toString();

    switch (action.toLowerCase()) {
        case 'gettree':
            treenet = net;
            commandQueue.push(`TREEXML ${net}\n`);
            break;
        case 'getall':
            commandQueue.push(`GET //${settings.cbusname}/${net}/${app}/* level\n`);
            break;
        case 'switch':
            if (msg === 'ON') commandQueue.push(`ON //${settings.cbusname}/${net}/${app}/${group}\n`);
            if (msg === 'OFF') commandQueue.push(`OFF //${settings.cbusname}/${net}/${app}/${group}\n`);
            break;
        case 'ramp':
            handleRampCommand(parts, msg);
            break;
        default:
            break;
    }
}

// Ramp command handler
function handleRampCommand(parts, message) {
    const [, , net, app, group] = parts;
    const address = `${net}/${app}/${group}`;
    const rampCmd = (level) =>
        commandQueue.push(`RAMP //${settings.cbusname}/${address} ${level}\n`);

    switch (message.toUpperCase()) {
        case 'INCREASE':
            eventEmitter.once('level', (addr, level) => {
                if (addr === address) rampCmd(Math.min(level + 26, 255));
            });
            commandQueue.push(`GET //${settings.cbusname}/${address} level\n`);
            break;
        case 'DECREASE':
            eventEmitter.once('level', (addr, level) => {
                if (addr === address) rampCmd(Math.max(level - 26, 0));
            });
            commandQueue.push(`GET //${settings.cbusname}/${address} level\n`);
            break;
        case 'ON':
            commandQueue.push(`ON //${settings.cbusname}/${address}\n`);
            break;
        case 'OFF':
            commandQueue.push(`OFF //${settings.cbusname}/${address}\n`);
            break;
        default: {
            const ramp = message.split(',');
            const num = Math.round((parseInt(ramp[0], 10) * 255) / 100);
            if (!isNaN(num) && num < 256) {
                const duration = ramp[1] ? ` ${ramp[1]}` : '';
                commandQueue.push(`RAMP //${settings.cbusname}/${address} ${num}${duration}\n`);
            }
        }
    }
}

// TCP connection handlers
const reconnect = (socket, port, host, label) => {
    setTimeout(() => {
        console.log(`${label} RECONNECTING...`);
        socket.connect(port, host);
    }, 10000);
};

command.on('connect', () => {
    commandConnected = true;
    console.log(`CONNECTED TO C-GATE COMMAND PORT: ${HOST}:${COMPORT}`);
    commandQueue.push('EVENT ON\n');
    started();
});

event.on('connect', () => {
    eventConnected = true;
    console.log(`CONNECTED TO C-GATE EVENT PORT: ${HOST}:${EVENTPORT}`);
    started();
});

command.on('close', () => {
    commandConnected = false;
    console.log('COMMAND PORT DISCONNECTED');
    reconnect(command, COMPORT, HOST, 'COMMAND PORT');
});

event.on('close', () => {
    eventConnected = false;
    console.log('EVENT PORT DISCONNECTED');
    reconnect(event, EVENTPORT, HOST, 'EVENT PORT');
});

command.on('error', (err) => {
    console.error('COMMAND ERROR:', err);
});

event.on('error', (err) => {
    console.error('EVENT ERROR:', err);
});

// Data handlers
command.on('data', (data) => {
    const lines = (buffer + data.toString()).split('\n');
    buffer = lines.pop();
    lines.forEach(processCommandLine);
});

function processCommandLine(line) {
    const parts1 = line.split('-');
    if (parts1.length > 1 && parts1[0] === '300') {
        processCbusStatus(parts1[1]);
    } else if (parts1[0] === '347') {
        tree += parts1[1] + '\n';
    } else if (parts1[0] === '343') {
        tree = '';
    } else if (parts1[0].split(' ')[0] === '344') {
        parseString(tree, (err, result) => {
            if (err) return console.error(err);
            if (logging) console.log('C-Bus tree received:', JSON.stringify(result));
            mqttQueue.push({
                topic: `cbus/read/${treenet}///tree`,
                payload: JSON.stringify(result),
            });
            tree = '';
        });
    } else {
        const parts2 = parts1[0].split(' ');
        if (parts2[0] === '300') processCbusStatus(parts2.slice(1).join(' '));
    }
}

function processCbusStatus(status) {
    const [addressStr, levelStr] = status.trim().split(' ');
    const address = addressStr.slice(0, -1).split('/');
    const level = parseInt(levelStr.split('=')[1], 10);
    const topicBase = `cbus/read/${address[3]}/${address[4]}/${address[5]}`;
    if (level === 0) {
        if (logging) console.log(`C-Bus status: ${topicBase} OFF (0%)`);
        mqttQueue.push({ topic: `${topicBase}/state`, payload: 'OFF' });
        mqttQueue.push({ topic: `${topicBase}/level`, payload: '0' });
        eventEmitter.emit('level', `${address[3]}/${address[4]}/${address[5]}`, 0);
    } else {
        const percent = Math.round((level * 100) / 255);
        if (logging) console.log(`C-Bus status: ${topicBase} ON (${percent}%)`);
        mqttQueue.push({ topic: `${topicBase}/state`, payload: 'ON' });
        mqttQueue.push({ topic: `${topicBase}/level`, payload: percent.toString() });
        eventEmitter.emit('level', `${address[3]}/${address[4]}/${address[5]}`, level);
    }
}

event.on('data', (data) => {
    const parts = data.toString().split(' ');
    if (parts[0] !== 'lighting') return;
    const address = parts[2].split('/');
    const topicBase = `cbus/read/${address[3]}/${address[4]}/${address[5]}`;
    switch (parts[1]) {
        case 'on':
            if (logging) console.log(`C-Bus status: ${topicBase} ON (100%)`);
            mqttQueue.push({ topic: `${topicBase}/state`, payload: 'ON' });
            mqttQueue.push({ topic: `${topicBase}/level`, payload: '100' });
            break;
        case 'off':
            if (logging) console.log(`C-Bus status: ${topicBase} OFF (0%)`);
            mqttQueue.push({ topic: `${topicBase}/state`, payload: 'OFF' });
            mqttQueue.push({ topic: `${topicBase}/level`, payload: '0' });
            break;
        case 'ramp': {
            const level = parseInt(parts[3], 10);
            const percent = Math.round((level * 100) / 255);
            if (level > 0) {
                if (logging) console.log(`C-Bus status: ${topicBase} ON (${percent}%)`);
                mqttQueue.push({ topic: `${topicBase}/state`, payload: 'ON' });
                mqttQueue.push({ topic: `${topicBase}/level`, payload: percent.toString() });
            } else {
                if (logging) console.log(`C-Bus status: ${topicBase} OFF (0%)`);
                mqttQueue.push({ topic: `${topicBase}/state`, payload: 'OFF' });
                mqttQueue.push({ topic: `${topicBase}/level`, payload: '0' });
            }
            break;
        }
        default:
            break;
    }
});

// Start connections
command.connect(COMPORT, HOST);
event.connect(EVENTPORT, HOST);
