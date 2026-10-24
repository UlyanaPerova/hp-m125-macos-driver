-- "Set Up Printer" - connects the USB printer to the m125-pclms driver.
-- SPDX-License-Identifier: MIT
set isRu to (user locale of (system info)) starts with "ru"
if isRu then
	set lang to "ru"
	set tTitle to "Принтер HP M125r"
	set tIntro to "Подключите принтер USB-кабелем и включите его. Затем нажмите «Продолжить»."
	set tGo to "Продолжить"
	set tCancel to "Отмена"
	set tTest to "Напечатать пробную страницу?"
	set tPrint to "Печать"
	set tNo to "Не сейчас"
	set tSent to "Пробная страница отправлена на принтер."
else
	set lang to "en"
	set tTitle to "HP M125r Printer"
	set tIntro to "Connect the printer with the USB cable and switch it on. Then click Continue."
	set tGo to "Continue"
	set tCancel to "Cancel"
	set tTest to "Print a test page?"
	set tPrint to "Print"
	set tNo to "Not now"
	set tSent to "The test page was sent to the printer."
end if

display dialog tIntro buttons {tCancel, tGo} default button tGo cancel button tCancel with title tTitle with icon note

try
	set out to do shell script "/Library/Printers/m125-pclms/setup-queue.sh " & lang with administrator privileges
on error errMsg number errNum
	if errNum is -128 then return -- user cancelled the password prompt
	display dialog errMsg buttons {"OK"} default button 1 with title tTitle with icon caution
	return
end try

set qName to ""
set msg to ""
repeat with l in paragraphs of out
	if l starts with "QUEUE=" then
		set qName to text 7 thru -1 of l
	else if (l as text) is not "" then
		set msg to msg & l & return
	end if
end repeat

set r to display dialog msg & return & tTest buttons {tNo, tPrint} default button tPrint with title tTitle with icon note
if button returned of r is tPrint and qName is not "" then
	do shell script "lp -d " & quoted form of qName & " /Library/Printers/m125-pclms/testpage.pdf"
	display dialog tSent buttons {"OK"} default button 1 with title tTitle with icon note
end if
