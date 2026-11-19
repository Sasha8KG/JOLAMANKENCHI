@echo off
chcp 65001 >nul
setlocal

echo ================================================
echo  ZHOL AMAN KENCHI - СОЗДАНИЕ ЛИЧНОГО КЛЮЧА APK
echo ================================================
echo.
echo Этот сценарий создаст файл jol-aman-kenchi-release.p12 в текущей папке.
echo Пароль вводится в окне keytool и не записывается в этот BAT-файл.
echo НЕ отправляйте файл .p12 и пароли никому и не загружайте их в GitHub.
echo.
where keytool >nul 2>nul
if errorlevel 1 (
  echo ОШИБКА: команда keytool не найдена.
  echo Установите Java JDK, содержащий keytool, затем запустите этот файл снова.
  echo Если на Windows 7 новая Java не устанавливается, используйте совместимую
  echo с вашей системой Java 8 JDK от доверенного поставщика.
  pause
  exit /b 1
)
if exist jol-aman-kenchi-release.p12 (
  echo ОШИБКА: jol-aman-kenchi-release.p12 уже существует.
  echo Не перезаписывайте существующий ключ. Сохраните его резервную копию.
  pause
  exit /b 1
)
keytool -genkeypair -v -keystore jol-aman-kenchi-release.p12 -storetype PKCS12 -alias jol-aman-kenchi-release -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=JOL AMAN KENCHI Taxi, OU=Taxi Fleet, O=JOL AMAN KENCHI, L=Suluktu, ST=Batken, C=KG"
if errorlevel 1 (
  echo.
  echo Ключ не создан. Проверьте сообщения keytool.
  pause
  exit /b 1
)
echo.
echo ГОТОВО. Проверьте наличие файла jol-aman-kenchi-release.p12.
echo Alias: jol-aman-kenchi-release
echo Запишите пароли в свой менеджер паролей и сделайте две защищённые резервные копии файла.
echo Не переименовывайте и не теряйте этот файл: он понадобится для всех будущих обновлений APK.
pause
endlocal
