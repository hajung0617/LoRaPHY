% Timed software LoRaPHY loopback for a UTF-8 text message.

script_dir = fileparts(mfilename('fullpath'));
project_dir = fileparts(fileparts(script_dir));
addpath(project_dir);

rf_freq = 470e6; % Required by the current constructor; unused by software loopback.
sf = 7;
bw = 125e3;
fs = 1e6;

phy = LoRaPHY(rf_freq, sf, bw, fs);
phy.has_header = 1;
phy.cr = 4;
phy.crc = 1;
phy.preamble_len = 8;

message = 'Hello World!';
payload = uint8(unicode2native(message, 'UTF-8'));
payload = payload(:);

% Measure the complete PHY loopback: encode, modulate, demodulate, decode.
loopback_timer = tic;
symbols = phy.encode(payload);
sig = phy.modulate(symbols);
[symbols_rx, ~, ~] = phy.demodulate(sig);
[data, checksum] = phy.decode(symbols_rx);
loopback_time = toc(loopback_timer);

if isempty(data) || isempty(checksum) || ...
        ~isequal(uint8(data(end-1:end)), uint8(checksum(:)))
    error('Loopback failed CRC validation.');
end

received_bytes = uint8(data(1:phy.payload_len));
received_text = native2unicode(received_bytes(:)', 'UTF-8');
if ~isequal(received_bytes, payload)
    error('Loopback payload does not match the transmitted message.');
end

fprintf('Message: %s (%d UTF-8 bytes)\n', message, numel(payload));
fprintf('Received: %s\n', received_text);
fprintf('PHY loopback processing time: %.6f s (%.3f ms)\n', ...
    loopback_time, loopback_time * 1e3);
