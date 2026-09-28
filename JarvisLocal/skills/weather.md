# Météo

Remplace get_weather. Utilise web_fetch sur Open-Meteo (api.open-meteo.com, sans clé) : géocodage puis forecast.

Recette : 1) geocoding-api.open-meteo.com/v1/search?name=VILLE ; 2) api.open-meteo.com/v1/forecast?latitude=..&longitude=..&current=temperature_2m ; 3) citer les chiffres lus, jamais de broderie.
