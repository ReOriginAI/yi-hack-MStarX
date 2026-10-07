var APP = APP || {};
APP.speak = (function($) {
    function report(message) { $('#audio-status').text(message); }
    function request(url, data, multipart) {
        report('Playing...');
        $('#button-speak, #button-speaker').prop('disabled', true);
        $.ajax({url: url, type: 'POST', data: data, processData: false,
            contentType: multipart ? false : 'text/plain; charset=UTF-8', dataType: 'json',
            success: function(response) { report(response.description || (response.error ? 'Playback failed' : 'Playback complete')); },
            error: function() { report('Audio request failed'); },
            complete: function() { $('#button-speak, #button-speaker').prop('disabled', false); }
        });
    }
    function init() {
        $(document).off('click.yiAudio', '#button-speak, #button-speaker, #button-audio-stop');
        $(document).on('click.yiAudio', '#button-speak', function() {
            var text = $('#ttsinput').val();
            if (!text) { report('Enter text to speak'); return; }
            request('cgi-bin/speak.sh?lang=' + encodeURIComponent($('#ttslang').val()) +
                '&voldb=' + encodeURIComponent($('#ttsvol').val()) +
                '&speed=' + encodeURIComponent($('#ttsspeed').val()) +
                '&pitch=' + encodeURIComponent($('#ttspitch').val()), text, false);
        });
        $(document).on('click.yiAudio', '#button-speaker', function() {
            var file = $('#wavfile').prop('files')[0];
            if (!file) { report('Choose a WAV or PCM file'); return; }
            if (file.size > 4194304) { report('Audio file exceeds 4 MiB'); return; }
            var data = new FormData(); data.append('file', file);
            request('cgi-bin/speaker.sh?voldb=' + encodeURIComponent($('#wavvol').val()), data, true);
        });
        $(document).on('click.yiAudio', '#button-audio-stop', function() {
            $.ajax({url: 'cgi-bin/speaker.sh?action=stop', dataType: 'json',
                success: function(response) { report(response.error ? response.description : 'Playback stopped'); },
                error: function() { report('Unable to stop playback'); }});
        });
    }
    return {init: init};
})(jQuery);
