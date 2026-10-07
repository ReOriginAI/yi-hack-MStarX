var APP = APP || {};

APP.wifi = (function($) {

    function init() {
        $('#input-container').hide();
        registerEventHandler();
        updateWiFiPage();
        fetchMaintenance();
    }

    function registerEventHandler() {
        $(document).on("click", '#button-save-wifi', function(e) {
            saveWiFi();
        });
        $(document).on("click", '#button-save-maintenance', saveMaintenance);
        $(document).on("change", '#WIFI_ESSID', function(e) {
            toggleESSIDInput();
        });
    }

    function saveWiFi() {
        var saveStatusElem;
        let configs = {};

        saveStatusElem = $('#save-wifi-status');
        saveStatusElem.text("Saving...");

        if ($('select[data-key="WIFI_ESSID"]').prop('value') == "Other...") {
            configs["WIFI_ESSID"] = $('input[type="text"][data-key="WIFI_ESSID_MANUAL"]').prop('value')
        } else {
            configs["WIFI_ESSID"] = $('select[data-key="WIFI_ESSID"]').prop('value');
        }
        configs["WIFI_PASSWORD"] = $('input[type="password"][data-key="WIFI_PASSWORD"]').prop('value');
        configs["WIFI_PASSWORD2"] = $('input[type="password"][data-key="WIFI_PASSWORD2"]').prop('value');

        if (configs["WIFI_ESSID"] == "") {
            saveStatusElem.text("Not saved, essid is blank.");
        } else if (configs["WIFI_PASSWORD"] == "") {
            saveStatusElem.text("Not saved, password is blank.");
        } else if (configs["WIFI_PASSWORD"] == "" || configs["WIFI_PASSWORD"] != configs["WIFI_PASSWORD2"]) {
            saveStatusElem.text("Not saved, passwords don't match.");
        } else {
            var configData = JSON.stringify(configs);
            var escapedConfigData = configData.replace(/\\/g, "\\")
                .replace(/\\"/g, '\\"');

            $.ajax({
                type: "POST",
                url: 'cgi-bin/wifi.sh?action=save',
                data: escapedConfigData,
                dataType: "json",
                success: function(response) {
                    if (!response || response.error === undefined) {
                        saveStatusElem.text("Not saved, generic error.");
                    } else if (response.error === true || response.error === "true") {
                        saveStatusElem.text("Not saved, passwords don't match.");
                    } else {
                        saveStatusElem.text("Saved");
                    }
                },
                error: function(response) {
                    saveStatusElem.text("Error while saving");
                    console.log('error', response);
                }
            });
        }
    }

    function updateWiFiPage() {
        loadingStatusElem = $('#loading-wifi-status');
        loadingStatusElem.text("Loading...");

        $.ajax({
            type: "GET",
            url: 'cgi-bin/wifi.sh?action=scan',
            dataType: "json",
            success: function(data) {
                loadingStatusElem.fadeOut(500);

                var select = $('<select>').attr({"data-key": "WIFI_ESSID", id: "WIFI_ESSID"});
                for (var i = 0; i < data.wifi.length; i++) {
                    if (data.wifi[i].length > 0) {
                        select.append($('<option>').val(data.wifi[i]).text(data.wifi[i]));
                    }
                }
                select.append($('<option>').val("Other...").text("Other..."));
                $('#select-container').empty().append(select);
            },
            error: function(response) {
                console.log('error', response);
            }
        });
    }

    function fetchMaintenance() {
        $.getJSON('cgi-bin/get_configs.sh?conf=system', function(configs) {
            $('#WIFI_MAINTENANCE_ENABLED').prop('checked', configs.WIFI_MAINTENANCE_ENABLED === 'yes');
            $('#WIFI_MAINTENANCE_SSID').val(configs.WIFI_MAINTENANCE_SSID || '');
            $('#WIFI_MAINTENANCE_PASSWORD').val(configs.WIFI_MAINTENANCE_PASSWORD || '');
        });
    }

    function saveMaintenance() {
        var status = $('#save-maintenance-status');
        status.text('Saving...');
        $.ajax({
            type: 'POST', url: 'cgi-bin/set_configs.sh?conf=system', dataType: 'json',
            data: JSON.stringify({
                WIFI_MAINTENANCE_ENABLED: $('#WIFI_MAINTENANCE_ENABLED').prop('checked') ? 'yes' : 'no',
                WIFI_MAINTENANCE_SSID: $('#WIFI_MAINTENANCE_SSID').val(),
                WIFI_MAINTENANCE_PASSWORD: $('#WIFI_MAINTENANCE_PASSWORD').val()
            }),
            success: function(result) { status.text(result.error ? 'Not saved: check network and password.' : 'Saved'); },
            error: function() { status.text('Error while saving'); }
        });
    }

    function toggleESSIDInput() {
        if ($("#WIFI_ESSID option:selected" ).text() == "Other...") {
            $('#input-container').show();
        } else {
            $('#input-container').hide();
        }
    }

    return {
        init: init
    };

})(jQuery);
