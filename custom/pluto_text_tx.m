% Send one UTF-8 text message as a LoRaPHY packet using PlutoSDR.
% Start pluto_text_rx.m on the receiving PlutoSDR first.

script_dir = fileparts(mfilename('fullpath'));
addpath(fileparts(script_dir));

radio_id = 'usb:0';       % Change to the ID reported by findPlutoRadio.
rf_freq = 263e6;        % KR920-923 default LoRaWAN channel; match RX.
sf = 7;
bw = 125e3;
fs = 1e6;
tx_gain = -30;
repeat_count = 3;         % Repeats the same message to make initial tests easier.
gap_s = 0.25;

message = input('Text to transmit: ', 's');
if isempty(message)
    error('Enter a non-empty message.');
end
payload = uint8(unicode2native(message, 'UTF-8'));
if numel(payload) > 255
    error('Message is too long: LoRaPHY supports at most 255 payload bytes.');
end

phy = LoRaPHY(rf_freq, sf, bw, fs);
phy.has_header = 1;
phy.cr = 1;                % Coding rate 4/5.
phy.crc = 1;
phy.preamble_len = 8;

symbols = phy.encode(payload(:));
signal = phy.modulate(symbols);
frame = complex(zeros(numel(signal) + round(gap_s*fs), 1));
frame(1:numel(signal)) = signal(:);
peak = max(abs(frame));
if peak > 0
    frame = 0.7 * frame / peak;
end

fprintf('TX %s (%d UTF-8 bytes) on %.3f MHz, SF%d, BW %.0f kHz\n', ...
    message, numel(payload), rf_freq/1e6, sf, bw/1e3);
fprintf('Start the receiver, then press Enter to transmit.\n');
pause;

tx = sdrtx('Pluto', ...
    'RadioID', radio_id, ...
    'CenterFrequency', rf_freq, ...
    'BasebandSampleRate', fs, ...
    'Gain', tx_gain);
tx_cleanup = onCleanup(@() release(tx));
disp(info(tx));

for k = 1:repeat_count
    tx(frame);
    fprintf('Sent message %d/%d\n', k, repeat_count);
end
release(tx);
fprintf('Transmission complete.\n');
