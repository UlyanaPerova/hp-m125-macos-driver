-- "Uninstall" - removes the m125-pclms printer driver.
-- SPDX-License-Identifier: MIT
set isRu to (user locale of (system info)) starts with "ru"
if isRu then
	set tTitle to "Удаление драйвера HP M125r"
	set tAsk to "Удалить драйвер принтера HP LaserJet Pro MFP M125r и этот принтер из списка принтеров?"
	set tYes to "Удалить"
	set tCancel to "Отмена"
	set tDone to "Драйвер удалён."
else
	set tTitle to "Uninstall HP M125r Driver"
	set tAsk to "Remove the HP LaserJet Pro MFP M125r printer driver and this printer from your printer list?"
	set tYes to "Uninstall"
	set tCancel to "Cancel"
	set tDone to "The driver has been removed."
end if

display dialog tAsk buttons {tCancel, tYes} default button tCancel cancel button tCancel with title tTitle with icon caution
try
	do shell script "/Library/Printers/m125-pclms/uninstall.sh" with administrator privileges
on error errMsg number errNum
	if errNum is -128 then return
	display dialog errMsg buttons {"OK"} default button 1 with title tTitle with icon stop
	return
end try
display dialog tDone buttons {"OK"} default button 1 with title tTitle with icon note
