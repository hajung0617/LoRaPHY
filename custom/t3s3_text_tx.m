% Send one UTF-8 text packet through the T3S3 SX1280 via USB serial.
% Upload t3s3_sx1280_tx.ino to the board first, then run this script.

port = "COM11";      % T3S3 USB serial port; change if Windows assigned another.
baud_rate = 115200;
max_payload_bytes = 255;
ready_timeout_s = 20;
tx_timeout_s = 20;

message = input('Text to transmit: ', 's');
if isempty(message)
    error('Enter a non-empty message.');
end
payload = uint8(unicode2native(message, 'UTF-8'));
if numel(payload) > max_payload_bytes
    error('UTF-8 payload is %d bytes; maximum is %d bytes.', ...
        numel(payload), max_payload_bytes);
end
if any(payload == 10)
    error('Line-feed characters cannot be sent in this serial line protocol.');
end

tx_serial = serialport(port, baud_rate, 'Timeout', 2);
configureTerminator(tx_serial, 'LF');
tx_cleanup = onCleanup(@() delete(tx_serial));

fprintf('Waiting for T3S3 SX1280 transmitter on %s...\n', port);
write(tx_serial, uint8([double('STATUS') 10]), 'uint8');
ready = false;
ready_timer = tic;
while toc(ready_timer) < ready_timeout_s
    if tx_serial.NumBytesAvailable > 0
        response = strtrim(readline(tx_serial));
        fprintf('T3S3: %s\n', response);
        if response == "READY"
            ready = true;
            break;
        elseif startsWith(response, "ERR:")
            error('T3S3 reported initialization error: %s', response);
        end
    else
        pause(0.05);
    end
end
if ~ready
    error('No READY response from T3S3. Check COM port and upload the transmitter sketch.');
end

% Send a command prefix, UTF-8 bytes, and LF; the board transmits one LoRa packet.
command = [uint8('TX:') payload(:).' uint8(10)];
write(tx_serial, command, 'uint8');
fprintf('Sent %d UTF-8 bytes to T3S3; waiting for transmit status...\n', numel(payload));

tx_done = false;
tx_timer = tic;
while toc(tx_timer) < tx_timeout_s
    if tx_serial.NumBytesAvailable > 0
        response = strtrim(readline(tx_serial));
        fprintf('T3S3: %s\n', response);
        if startsWith(response, "TX_OK:")
            tx_done = true;
            break;
        elseif startsWith(response, "ERR:")
            error('T3S3 transmission failed: %s', response);
        end
    else
        pause(0.05);
    end
end
if ~tx_done
    error('Timed out waiting for the T3S3 transmit status.');
end
fprintf('Transmission complete.\n');
