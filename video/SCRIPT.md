# CoShare: فيديو تعريفي (٦٠ ثانية)

النص بالعربي والإنجليزي، جاهز لـ ElevenLabs، ومقسّم على ٧ مشاهد مضبوطة على توقيت الأنيميشن.
الأنيميشن نفسه موجود بـ `video/animation/index.html`. افتحه بالمتصفح وبيشتغل مباشرة، أو استخدم الفيديو المرندر بـ `website/assets/video/`.

---

## إعدادات ElevenLabs المقترحة

| الإعداد | القيمة |
|---|---|
| الموديل | **Eleven Multilingual v2** (الأثبت للعربي). أو **Eleven v3** إذا بدك تعبير أكتر |
| Stability | ٥٠٪ |
| Similarity | ٧٥٪ |
| Style | ٢٠٪ |
| Speaker boost | مفعّل |
| السرعة | ١٫٠ (أو ٠٫٩٥ للعربي إذا طلع سريع) |

- **الصوت:** من Voice Library اختار صوت راوي هادي وواثق. للعربي دوّر على "Arabic narrator" أو "MSA"، ولازم يكون فصحى، مش لهجة. وللإنجليزي "warm narrator" أو "conversational".
- **أفضل طريقة:** ولّد **كل مشهد لحاله** (٧ ملفات صغيرة)، حتى تقدر تعيد مشهد واحد بدون ما تعيد الكل. ولو بدك ملف واحد، استخدم النص الكامل تحت؛ وسوم `<break>` بتعمل الوقفات بين المشاهد (شغّالة بـ Multilingual v2، مش بـ v3).
- ابعتلي ملفات الصوت (MP3)، وأنا بضبط توقيت الأنيميشن عليها بالضبط وبدمجهم بفيديو نهائي.

---

## المشاهد

| # | الوقت | المشهد | النص العربي | English narration |
|---|---|---|---|---|
| 1 | 0:00–0:07 | **الخطّاف (Hook).** آيفون بتوصله رسالة «رمز التحقق 482 913»، وجنبه لابتوب فيه خانة كود فاضية والمؤشر عم يرمش. | وصلك رمزٌ على هاتفك… وتحتاجه الآن على حاسوبك. | A code just landed on your phone… and you need it on your laptop. Right now. |
| 2 | 0:07–0:15 | **المشكلة.** آيفون وماك وأندرويد وويندوز، كل واحد بـ «حساب مختلف»، وبيناتهم ✗ حمرا. | فتكتبه بيدك… أو ترسله لنفسك. لأنّ أجهزتك لا تتشارك الحافظة: حساباتٌ مختلفة، وأنظمةٌ مختلفة. | So you retype it… or message it to yourself. Because your devices don't share a clipboard — different accounts, different systems. |
| 3 | 0:15–0:24 | **الحل.** شعار CoShare بيظهر بتوهج، والأجهزة الخمسة بتلتف حوله وبتنوصل بخطوط. | تعرّف على CoShare: حافظةٌ واحدة لكل أجهزتك. آيفون، أندرويد، ماك، ويندوز ولينكس… وبأيّ حساب. | Meet CoShare. One clipboard for all your devices — iPhone, Android, Mac, Windows and Linux. Any account. |
| 4 | 0:24–0:34 | **العرض.** «نسخ» على الآيفون، والكود بيطير للابتوب وبينلصق ✓. بعدها لقطة شاشة بتطير للويندوز والأندرويد. | انسخ على أيّ جهاز… وستجده جاهزاً للّصق على البقية، فوراً. نصوصاً كانت، أو صوراً بجودتها الكاملة. | Copy on any device… and it's instantly ready to paste on the others. Text, or images at full quality. |
| 5 | 0:34–0:44 | **الشبكة.** راوتر واي فاي بالنص والأجهزة حوله وحزم بيانات رايحة جاية، وفوق سحابة عليها خط «بلا سحابة»، وشارة قفل. | بلا سحابة، ولا خوادم. يعمل CoShare على شبكتك أنت؛ أجهزتك تتحدّث مباشرة… وبتشفيرٍ كامل. | No cloud. No servers. CoShare runs on your own Wi-Fi — your devices talk directly, fully encrypted. |
| 6 | 0:44–0:53 | **الأمان.** جهازين ظاهر عليهم نفس الرمز «974 291»، وبتنكبس «سماح» ✓. بعدها جهاز غريب رمادي عليه درع ✗. | وبخصوصيةٍ تامة: اربط أجهزتك مرةً واحدة، برمز QR أو برمزٍ من ستة أرقام. أمّا الغريب على الشبكة نفسها… فلا يرى شيئاً. | And it's private. Pair your devices once — with a QR code or a six-digit match. A stranger on the same Wi-Fi? Sees nothing. |
| 7 | 0:53–1:00 | **الختام.** الشعار، وتحته «انسخ هنا، الصق هناك» وأيقونات المنصات، و«مجاني · بدون حساب». | CoShare… انسخ هنا، والصق هناك. مجاناً، على كل أجهزتك. | CoShare. Copy here. Paste there. Free, on every device. |

---

> ⚠️ **تحديث مطلوب للمشهد ٦:** التطبيق صار يعتمد على **مجموعات بكلمة سر** بدل رمز الـ ٦ أرقام. ولّد هالجملة من جديد بنفس الصوت، وابعتلي ياها لأحدّث المشهد:
> - **العربي:** وبخصوصيةٍ تامة: أنشئ مجموعتك بكلمة سر مرةً واحدة، وانضم لها من أجهزتك أو بمسح رمز QR. أمّا الغريب على الشبكة نفسها… فلا يرى شيئاً.
> - **English:** And it's private. Create your group with a password once — join from your devices, or just scan a QR code. A stranger on the same Wi-Fi? Sees nothing.

## النص الكامل (لصق مباشر بـ ElevenLabs)

### العربي

```text
وصلك رمزٌ على هاتفك… وتحتاجه الآن على حاسوبك.
<break time="0.6s" />
فتكتبه بيدك… أو ترسله لنفسك. لأنّ أجهزتك لا تتشارك الحافظة: حساباتٌ مختلفة، وأنظمةٌ مختلفة.
<break time="0.7s" />
تعرّف على CoShare: حافظةٌ واحدة لكل أجهزتك. آيفون، أندرويد، ماك، ويندوز ولينكس… وبأيّ حساب.
<break time="0.7s" />
انسخ على أيّ جهاز… وستجده جاهزاً للّصق على البقية، فوراً. نصوصاً كانت، أو صوراً بجودتها الكاملة.
<break time="0.7s" />
بلا سحابة، ولا خوادم. يعمل CoShare على شبكتك أنت؛ أجهزتك تتحدّث مباشرة… وبتشفيرٍ كامل.
<break time="0.7s" />
وبخصوصيةٍ تامة: اربط أجهزتك مرةً واحدة، برمز QR أو برمزٍ من ستة أرقام. أمّا الغريب على الشبكة نفسها… فلا يرى شيئاً.
<break time="0.8s" />
CoShare… انسخ هنا، والصق هناك. مجاناً، على كل أجهزتك.
```

> «CoShare» بيتلفظ **«كو-شير»**. إذا لفظه الصوت غلط، اكتبه بالنص «كو شير».

### English

```text
A code just landed on your phone… and you need it on your laptop. Right now.
<break time="0.6s" />
So you retype it… or message it to yourself. Because your devices don't share a clipboard — different accounts, different systems.
<break time="0.7s" />
Meet CoShare. One clipboard for all your devices — iPhone, Android, Mac, Windows and Linux. Any account.
<break time="0.7s" />
Copy on any device… and it's instantly ready to paste on the others. Text, or images at full quality.
<break time="0.7s" />
No cloud. No servers. CoShare runs on your own Wi-Fi — your devices talk directly, fully encrypted.
<break time="0.7s" />
And it's private. Pair your devices once — with a QR code or a six-digit match. A stranger on the same Wi-Fi? Sees nothing.
<break time="0.8s" />
CoShare. Copy here. Paste there. Free, on every device.
```

> Pronounced **"co-share"**.

---

## الموسيقى والمؤثرات (اختياري)

- **موسيقى خلفية:** إلكترونية هادية وإيجابية (corporate / tech, 100–110 BPM)، على ‎-18 dB تحت الصوت. فيك تولّدها من **ElevenLabs Music** بوصف متل: *"minimal uplifting tech background, soft synth plucks, light percussion, 60 seconds, no vocals"*.
- **مؤثرات** (ElevenLabs Sound Effects):
  - 0:01 «دينغ» وصول رسالة
  - 0:25 «woosh» خفيف لما يطير الكود
  - 0:27 «تك» تأكيد اللصق
  - 0:48 «تك» زر السماح
  - 0:53 «whoosh» صاعد للشعار

## الألوان والخط (لأي تعديل أو مونتاج)

| العنصر | القيمة |
|---|---|
| الخلفية | `#05070F` |
| تدرّج العلامة | `#3E8BFF` ← `#7A4DFF` ← `#C04DFF` |
| أخضر النجاح | `#3BE38B` |
| أحمر | `#FF5D6C` |
| الخط | **Readex Pro** (عربي + لاتيني) من Google Fonts |
| المقاس | 1920×1080، ‏30fps |
